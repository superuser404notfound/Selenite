#include <stdatomic.h>
#include "include/MoonlightCore.h"

static _Atomic(MLLogSink) logSink = NULL;

void MLSetLogSink(MLLogSink sink) {
    atomic_store(&logSink, sink);
}

MLLogSink MLGetLogSink(void) {
    return atomic_load(&logSink);
}
