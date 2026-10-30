/// The web has no `dart:ffi` and no native crash to provoke: the lab's
/// collector is inert there, and so are these.
void ffiAbort() {}

void ffiNullWrite() {}
