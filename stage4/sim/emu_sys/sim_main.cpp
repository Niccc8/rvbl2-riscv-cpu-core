// sim_main.cpp - the whole-system simulation for the Stage 4 pre-flight gate (G3).
//
// The organisers' top.sv (unchanged) + our riscv.sv, Verilated, driven by the
// organisers' emu.c itself (unchanged, built as libemu.so with main -> emu_main).
// emu's fpga_pci_peek/poke become AXI4-Lite transactions on top.sv's OCL port, and
// its usleep() advances simulated time (clk_main_a0 = 250 MHz). The FPGA keeps its
// state between command lines, as the real one does; each line loads a fresh copy
// of libemu.so, so emu's static read pointer starts at 0 as in a new process.
//
//   sim_emu --lines FILE [--scale S] [--only N] [--negative] [--max-access N]
//
// FILE holds "./emu ..." lines (application/emulator-preview/emu_commands.txt).
// --scale S simulates S x emu's real 50 ms waits (1.0 = exact). A line passes when
// emu prints no "[error]" (emu's exit status is inverted and does not tell
// mismatches apart, so the text is the verdict, as on the F2). --negative adds
// lines with one expected value corrupted, which must fail. A line that makes more
// than --max-access register accesses is reported as a HANG (e.g. emu polling a
// TX-done flag that never rises).
#include "Vtop.h"
#include "verilated.h"
#include <csetjmp>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <dlfcn.h>
#include <fcntl.h>
#include <fstream>
#include <getopt.h>
#include <sstream>
#include <string>
#include <unistd.h>
#include <vector>

extern "C" {
#include "fpga_mgmt.h"
#include "fpga_pci.h"
}

static Vtop *dut;
static uint64_t cycles = 0;
static double scale = 1.0;
static long accesses = 0, max_access = 3000;
static jmp_buf hang_jmp;
static bool in_line = false;

static void tick() {
    dut->clk_main_a0 = 0;
    dut->eval();
    dut->clk_main_a0 = 1;
    dut->eval();
    cycles++;
}

static void count_access() {
    if (in_line && ++accesses > max_access) longjmp(hang_jmp, 1);
}

// AXI4-Lite master, as the Shell drives the OCL port: AW and W together, wait for
// both handshakes, then B. top.sv raises bvalid one extra cycle after the B
// handshake; bready is dropped right after the first one.
static void axi_write(uint32_t addr, uint32_t data) {
    dut->ocl_cl_awaddr = addr;
    dut->ocl_cl_awvalid = 1;
    dut->ocl_cl_wdata = data;
    dut->ocl_cl_wstrb = 0xF;
    dut->ocl_cl_wvalid = 1;
    dut->ocl_cl_bready = 0;
    bool aw = false, w = false;
    for (int guard = 0; !(aw && w); guard++) {
        bool awr = dut->cl_ocl_awready, wr = dut->cl_ocl_wready;
        tick();
        if (!aw && awr) { aw = true; dut->ocl_cl_awvalid = 0; }
        if (!w && wr) { w = true; dut->ocl_cl_wvalid = 0; }
        if (guard > 1000) { fprintf(stderr, "AXI write 0x%02X: no handshake\n", addr); exit(2); }
    }
    dut->ocl_cl_bready = 1;
    for (int guard = 0; !dut->cl_ocl_bvalid; guard++) {
        tick();
        if (guard > 1000) { fprintf(stderr, "AXI write 0x%02X: no response\n", addr); exit(2); }
    }
    tick();
    dut->ocl_cl_bready = 0;
    tick();
    tick();
}

static uint32_t axi_read(uint32_t addr) {
    dut->ocl_cl_araddr = addr;
    dut->ocl_cl_arvalid = 1;
    dut->ocl_cl_rready = 0;
    for (int guard = 0;; guard++) {
        bool ar = dut->cl_ocl_arready;
        tick();
        if (ar) break;
        if (guard > 1000) { fprintf(stderr, "AXI read 0x%02X: no handshake\n", addr); exit(2); }
    }
    dut->ocl_cl_arvalid = 0;
    dut->ocl_cl_rready = 1;
    for (int guard = 0; !dut->cl_ocl_rvalid; guard++) {
        tick();
        if (guard > 1000) { fprintf(stderr, "AXI read 0x%02X: no data\n", addr); exit(2); }
    }
    uint32_t v = dut->cl_ocl_rdata;
    tick();
    dut->ocl_cl_rready = 0;
    tick();
    return v;
}

static void wait_us(double us) {
    uint64_t n = (uint64_t)(us * 250.0 * scale);
    for (uint64_t i = 0; i < n; i++) tick();
}

// ---- the AWS SDK as emu.c sees it ----------------------------------------
extern "C" int fpga_mgmt_init(void) { return 0; }
extern "C" int fpga_pci_attach(int, int, int, uint32_t, pci_bar_handle_t *h) { *h = 1; return 0; }
extern "C" int fpga_pci_detach(pci_bar_handle_t) { return 0; }
extern "C" int fpga_pci_poke(pci_bar_handle_t, uint64_t off, uint32_t v) {
    count_access();
    axi_write((uint32_t)off, v);
    return 0;
}
extern "C" int fpga_pci_peek(pci_bar_handle_t, uint64_t off, uint32_t *v) {
    count_access();
    *v = axi_read((uint32_t)off);
    return 0;
}
// emu.c's DELAY(): resolved here, not in libc (the executable is linked -rdynamic)
extern "C" int usleep(useconds_t us) {
    wait_us((double)us);
    return 0;
}

// ---- one ./emu command line --------------------------------------------------
typedef int (*emu_main_t)(int, char **);

struct Line {
    std::string title;
    std::vector<std::string> args;
    bool expect_error;
};

static std::string run_emu(const Line &ln, int n, bool *hung) {
    char so[256], out[256];
    snprintf(so, sizeof so, "/tmp/libemu_%d_%d.so", (int)getpid(), n);
    snprintf(out, sizeof out, "/tmp/emu_out_%d_%d.txt", (int)getpid(), n);
    std::string cmd = std::string("cp libemu.so ") + so;
    if (system(cmd.c_str()) != 0) { perror("cp"); exit(2); }
    void *h = dlopen(so, RTLD_NOW | RTLD_LOCAL);
    if (!h) { fprintf(stderr, "dlopen: %s\n", dlerror()); exit(2); }
    emu_main_t emu_main = (emu_main_t)dlsym(h, "emu_main");
    if (!emu_main) { fprintf(stderr, "dlsym emu_main: %s\n", dlerror()); exit(2); }

    std::vector<char *> argv;
    std::vector<std::string> store = {"./emu"};
    store.insert(store.end(), ln.args.begin(), ln.args.end());
    for (auto &s : store) argv.push_back(&s[0]);
    argv.push_back(nullptr);

    fflush(stdout);
    fflush(stderr);
    int saved_out = dup(1), saved_err = dup(2);
    int fd = open(out, O_CREAT | O_TRUNC | O_WRONLY, 0644);
    dup2(fd, 1);
    dup2(fd, 2);
    close(fd);
    optind = 0;                       // glibc: full getopt re-initialisation
    accesses = 0;
    in_line = true;
    *hung = false;
    if (setjmp(hang_jmp) == 0) {
        emu_main((int)store.size(), argv.data());
    } else {
        *hung = true;
    }
    in_line = false;
    fflush(stdout);
    fflush(stderr);
    dup2(saved_out, 1);
    dup2(saved_err, 2);
    close(saved_out);
    close(saved_err);
    dlclose(h);
    unlink(so);
    std::ifstream f(out);
    std::stringstream ss;
    ss << f.rdbuf();
    unlink(out);
    return ss.str();
}

static std::vector<Line> load_lines(const char *path, bool negative) {
    std::vector<Line> v;
    std::ifstream f(path);
    if (!f) { fprintf(stderr, "cannot read %s\n", path); exit(2); }
    std::string s, title;
    while (std::getline(f, s)) {
        if (s.rfind("# ", 0) == 0) { title = s.substr(2); continue; }
        if (s.rfind("./emu ", 0) != 0) continue;
        Line ln;
        ln.title = title;
        ln.expect_error = false;
        std::istringstream is(s.substr(6));
        std::string t;
        while (is >> t) ln.args.push_back(t);
        v.push_back(ln);
    }
    if (negative && !v.empty()) {
        // the first line with a wrong lamp value, and the last with a wrong record
        Line a = v.front();
        for (size_t i = a.args.size(); i-- > 0;)
            if (a.args[i] == "-o") {
                unsigned long x = strtoul(a.args[i + 1].c_str(), nullptr, 0) ^ 0x10;
                char b[16]; snprintf(b, sizeof b, "0x%02lX", x); a.args[i + 1] = b; break;
            }
        a.title = "NEGATIVE: " + a.title + " (lamp value corrupted)";
        a.expect_error = true;
        v.push_back(a);
        Line r = v[v.size() - 2];
        for (size_t i = r.args.size(); i-- > 0;)
            if (r.args[i] == "-r4") {
                unsigned long x = strtoul(r.args[i + 1].c_str(), nullptr, 0) ^ 0x01000000;
                char b[16]; snprintf(b, sizeof b, "0x%08lX", x); r.args[i + 1] = b; break;
            }
        r.title = "NEGATIVE: " + r.title + " (record byte corrupted)";
        r.expect_error = true;
        v.push_back(r);
    }
    return v;
}

int main(int argc, char **argv) {
    const char *lines_path = nullptr;
    int only = 0;
    bool negative = false;
    for (int i = 1; i < argc; i++) {
        std::string a = argv[i];
        if (a == "--lines" && i + 1 < argc) lines_path = argv[++i];
        else if (a == "--scale" && i + 1 < argc) scale = atof(argv[++i]);
        else if (a == "--only" && i + 1 < argc) only = atoi(argv[++i]);
        else if (a == "--negative") negative = true;
        else if (a == "--max-access" && i + 1 < argc) max_access = atol(argv[++i]);
    }
    if (!lines_path) { fprintf(stderr, "usage: sim_emu --lines FILE [--scale S] [--only N] [--negative]\n"); return 2; }
    std::vector<Line> lines = load_lines(lines_path, negative);

    dut = new Vtop;
    dut->rst_main_n = 0;
    for (int i = 0; i < 32; i++) tick();
    dut->rst_main_n = 1;                 // the AFI is loaded: riscv_nreset = 1, the core runs
    for (int i = 0; i < 1000; i++) tick();

    int pass = 0, fail = 0;
    printf("============================================================\n");
    printf(" Stage 4 system simulation: organisers' emu.c -> top.sv -> riscv.sv\n");
    printf(" clk_main_a0 250 MHz; emu waits simulated at %.2f x real\n", scale);
    printf("============================================================\n");

    // Bring-up ladder, step 0: the PC moves, inside the ROM (0x1C, as ./axil_rw would read it)
    wait_us(2000);
    uint32_t pc1 = axi_read(0x1C);
    wait_us(1000);
    uint32_t pc2 = axi_read(0x1C);
    uint32_t rst = axi_read(0x00);
    bool pc_ok = pc1 != pc2 && pc1 >= 0x00400000u && pc1 < 0x00404000u && pc2 >= 0x00400000u &&
                 pc2 < 0x00404000u && rst == 1;
    printf("\n-- 0. bring-up: RST reads %u; PC reads 0x%08X then 0x%08X: %s\n", rst, pc1, pc2,
           pc_ok ? "running in ROM" : "NOT RUNNING");
    if (pc_ok) { printf("PASS bring-up\n"); pass++; } else { printf("FAIL bring-up\n"); fail++; }

    for (size_t k = 0; k < lines.size(); k++) {
        if (only && (int)k + 1 != only) continue;
        const Line &ln = lines[k];
        printf("\n-- %zu. %s\n$ ./emu", k + 1, ln.title.c_str());
        for (auto &a : ln.args) printf(" %s", a.c_str());
        printf("\n");
        uint64_t c0 = cycles;
        bool hung;
        std::string out = run_emu(ln, (int)k, &hung);
        printf("%s", out.c_str());
        bool err = out.find("[error]") != std::string::npos || hung;
        if (hung) printf("HANG: more than %ld register accesses\n", max_access);
        bool ok = err == ln.expect_error;
        printf("%s line %zu%s (%.1f ms simulated)\n", ok ? "PASS" : "FAIL", k + 1,
               ln.expect_error ? (err ? ": emu reports the error, as it must" : ": emu missed the error") : "",
               (double)(cycles - c0) / 250000.0);
        fflush(stdout);
        if (ok) pass++; else fail++;
    }
    printf("\n==== emu_sys: %d passed, %d failed, %.3f s simulated ====\n", pass, fail, (double)cycles / 250e6);
    printf(fail ? "EMU_SYS: FAILURES PRESENT\n" : "EMU_SYS: ALL TESTS PASSED\n");
    delete dut;
    return fail ? 1 : 0;
}
