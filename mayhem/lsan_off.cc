// mayhem/lsan_off.cc -- turn LeakSanitizer off at BUILD time for every sanitized upx binary.
//
// Fleet policy (SPEC 6.2 item 15): leaks are not the bug class this fleet fuzzes for -- ASan's
// memory-corruption checks and UBSan are -- but `-fsanitize=address` always bundles LSan in and
// there is no flag that keeps ASan while dropping only leak detection. UPX allocates per input and
// is not leak-clean by design (it relies on process exit), and the libFuzzer harness calls
// upx_main() thousands of times in ONE process, so leaving LSan on would drown every run in
// leak reports instead of memory-safety findings.
//
// This is the sanctioned mechanism: a linked translation unit defining __lsan_is_turned_off().
// It is deliberately NOT a runtime __lsan_disable()/__lsan_enable() wrap, and NOT a compiled-in
// sanitizer default-options override of any kind -- Mayhem alone owns the runtime option set, and
// the gate FAILs on both. ASan and UBSan stay fully active and halting.
extern "C" int __lsan_is_turned_off(void) { return 1; }
