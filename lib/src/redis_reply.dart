import 'dart:ffi';

import 'package:ffi/ffi.dart';

import 'hiredis_bindings.g.dart';

/// The type of a Redis reply.
enum RedisReplyType {
  string(REDICT_REPLY_STRING),
  array(REDICT_REPLY_ARRAY),
  integer(REDICT_REPLY_INTEGER),
  nil(REDICT_REPLY_NIL),
  status(REDICT_REPLY_STATUS),
  error(REDICT_REPLY_ERROR),
  double_(REDICT_REPLY_DOUBLE),
  bool_(REDICT_REPLY_BOOL),
  map(REDICT_REPLY_MAP),
  set(REDICT_REPLY_SET),
  attr(REDICT_REPLY_ATTR),
  push(REDICT_REPLY_PUSH),
  bignum(REDICT_REPLY_BIGNUM),
  verb(REDICT_REPLY_VERB);

  const RedisReplyType(this.value);
  final int value;

  static RedisReplyType fromValue(int value) {
    return RedisReplyType.values.firstWhere(
      (e) => e.value == value,
      orElse: () => throw ArgumentError('Unknown reply type: $value'),
    );
  }
}

/// A wrapper around a hiredis reply object with automatic memory management.
///
/// This class implements [Finalizable] to prevent premature garbage collection
/// during FFI calls. The native reply is automatically freed when this object
/// is garbage collected, or can be freed manually with [free].
final class RedisReply implements Finalizable {
  /// The native finalizer that calls freeReplyObject.
  static NativeFinalizer? _finalizer;

  /// Initialize the finalizer with the dynamic library.
  static void _ensureFinalizerInitialized(DynamicLibrary dylib) {
    if (_finalizer == null) {
      final freeReplyObjectPtr = dylib
          .lookup<NativeFunction<Void Function(Pointer<Void>)>>(
            'freeReplyObject',
          );
      _finalizer = NativeFinalizer(freeReplyObjectPtr.cast());
    }
  }

  final HiredisBindings _bindings;
  final DynamicLibrary _dylib;
  final Pointer<redictReply> _reply;
  bool _freed = false;

  /// Creates a RedisReply wrapper around a native reply pointer.
  ///
  /// The reply will be automatically freed when this object is garbage
  /// collected, unless [free] is called first.
  RedisReply._(this._bindings, this._dylib, this._reply) {
    _ensureFinalizerInitialized(_dylib);
    _finalizer!.attach(this, _reply.cast(), detach: this);
  }

  /// Creates a RedisReply from a raw pointer.
  ///
  /// Returns null if the pointer is null.
  static RedisReply? fromPointer(
    HiredisBindings bindings,
    DynamicLibrary dylib,
    Pointer<Void> pointer,
  ) {
    if (pointer == nullptr) return null;
    return RedisReply._(bindings, dylib, pointer.cast<redictReply>());
  }

  /// The type of this reply.
  RedisReplyType get type {
    _checkNotFreed();
    return RedisReplyType.fromValue(_reply.ref.type);
  }

  /// The integer value of this reply (for integer replies).
  int get integer {
    _checkNotFreed();
    return _reply.ref.integer;
  }

  /// The double value of this reply (for double replies).
  double get doubleValue {
    _checkNotFreed();
    return _reply.ref.dval;
  }

  /// The string value of this reply (for string, status, error replies).
  String? get string {
    _checkNotFreed();
    final str = _reply.ref.str;
    if (str == nullptr) return null;
    final len = _reply.ref.len;
    // Use the length field for binary-safe string reading
    return str.cast<Utf8>().toDartString(length: len);
  }

  /// The number of elements in this reply (for array replies).
  int get length {
    _checkNotFreed();
    return _reply.ref.elements;
  }

  /// Gets an element from an array reply.
  RedisReply? operator [](int index) {
    _checkNotFreed();
    if (index < 0 || index >= length) {
      throw RangeError.index(index, this, 'index', null, length);
    }
    final elementPtr = _reply.ref.element[index];
    if (elementPtr == nullptr) return null;
    // Note: Child elements are owned by the parent reply and will be freed
    // when the parent is freed. We don't attach a finalizer to them.
    return _RedisReplyChild._(_bindings, _dylib, elementPtr);
  }

  /// Whether this is an error reply.
  bool get isError => type == RedisReplyType.error;

  /// Whether this is a nil reply.
  bool get isNil => type == RedisReplyType.nil;

  /// Returns the value as a dynamic Dart object based on the reply type.
  Object? get value {
    _checkNotFreed();
    switch (type) {
      case RedisReplyType.string:
      case RedisReplyType.status:
      case RedisReplyType.verb:
      case RedisReplyType.bignum:
        return string;
      case RedisReplyType.error:
        return string;
      case RedisReplyType.integer:
        return integer;
      case RedisReplyType.double_:
        return doubleValue;
      case RedisReplyType.bool_:
        return integer != 0;
      case RedisReplyType.nil:
        return null;
      case RedisReplyType.array:
      case RedisReplyType.set:
      case RedisReplyType.push:
        return List.generate(length, (i) => this[i]?.value);
      case RedisReplyType.map:
      case RedisReplyType.attr:
        final result = <Object?, Object?>{};
        for (var i = 0; i < length; i += 2) {
          final key = this[i]?.value;
          final val = this[i + 1]?.value;
          result[key] = val;
        }
        return result;
    }
  }

  /// Manually frees the native reply object.
  ///
  /// After calling this method, the reply can no longer be used.
  void free() {
    if (_freed) return;
    _finalizer!.detach(this);
    _bindings.freeReplyObject(_reply.cast());
    _freed = true;
  }

  void _checkNotFreed() {
    if (_freed) {
      throw StateError('RedisReply has been freed');
    }
  }

  @override
  String toString() {
    if (_freed) return 'RedisReply(freed)';
    return 'RedisReply(type: $type, value: $value)';
  }
}

/// A child reply that doesn't own its memory (owned by parent).
final class _RedisReplyChild extends RedisReply {
  _RedisReplyChild._(super.bindings, super.dylib, super.reply) : super._() {
    // Detach from finalizer since parent owns this memory
    RedisReply._finalizer!.detach(this);
    _freed = false; // Reset since we don't want to track freed state
  }

  @override
  void free() {
    // Do nothing - parent owns this memory
  }
}
