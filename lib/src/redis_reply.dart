import 'dart:ffi';

import 'package:ffi/ffi.dart';

import 'hiredis_bindings.g.dart';

/// The type of a Redis reply.
enum RedisReplyType {
  string(REDIS_REPLY_STRING),
  array(REDIS_REPLY_ARRAY),
  integer(REDIS_REPLY_INTEGER),
  nil(REDIS_REPLY_NIL),
  status(REDIS_REPLY_STATUS),
  error(REDIS_REPLY_ERROR),
  double_(REDIS_REPLY_DOUBLE),
  bool_(REDIS_REPLY_BOOL),
  map(REDIS_REPLY_MAP),
  set(REDIS_REPLY_SET),
  attr(REDIS_REPLY_ATTR),
  push(REDIS_REPLY_PUSH),
  bignum(REDIS_REPLY_BIGNUM),
  verb(REDIS_REPLY_VERB);

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
  static final _finalizer = NativeFinalizer(
    Native.addressOf<NativeFunction<Void Function(Pointer<Void>)>>(
      freeReplyObject,
    ).cast(),
  );

  final Pointer<redisReply> _reply;
  bool _freed = false;

  /// Creates a RedisReply wrapper around a native reply pointer.
  ///
  /// The reply will be automatically freed when this object is garbage
  /// collected, unless [free] is called first.
  RedisReply._(this._reply) {
    _finalizer.attach(this, _reply.cast(), detach: this);
  }

  /// Creates a RedisReply from a raw pointer.
  ///
  /// Returns null if the pointer is null.
  static RedisReply? fromPointer(Pointer<Void> pointer) {
    if (pointer == nullptr) return null;
    return RedisReply._(pointer.cast<redisReply>());
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
    return _RedisReplyChild._(elementPtr);
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
    _finalizer.detach(this);
    freeReplyObject(_reply.cast());
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
  _RedisReplyChild._(super.reply) : super._() {
    // Detach from finalizer since parent owns this memory
    RedisReply._finalizer.detach(this);
    _freed = false; // Reset since we don't want to track freed state
  }

  @override
  void free() {
    // Do nothing - parent owns this memory
  }
}
