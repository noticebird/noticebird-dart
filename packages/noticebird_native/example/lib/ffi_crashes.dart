import 'dart:ffi';

/// `abort()` from the C library: SIGABRT.
void ffiAbort() => DynamicLibrary.process()
    .lookupFunction<Void Function(), void Function()>('abort')();

/// A write to address zero: SIGSEGV (`EXC_BAD_ACCESS` on iOS).
void ffiNullWrite() => Pointer<Int32>.fromAddress(0).value = 1;
