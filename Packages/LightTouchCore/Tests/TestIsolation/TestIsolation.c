// Every LightTouchCore test process gets a private home and app state before anything reads them: Bundled,
// logEvent, the IPA library and the caches resolve through LTM_STATE_DIR and the user's home, so a test that forgets
// to isolate itself still never touches the real library (~/Library/Application Support, Logs, Caches).
#include <ftw.h>
#include <limits.h>
#include <stdio.h>
#include <stdlib.h>
#include <sys/stat.h>
#include <unistd.h>
#include "TestIsolation.h"

static char root[PATH_MAX];
static char home[PATH_MAX];

static int remove_entry(const char *path, const struct stat *sb, int flag, struct FTW *ftw) {
    (void)sb;
    (void)flag;
    (void)ftw;
    return remove(path);
}

static void cleanup(void) {
    if (root[0])
        nftw(root, remove_entry, 16, FTW_DEPTH | FTW_PHYS);
}

__attribute__((constructor)) static void isolate(void) {
    // An exit test's child process (#expect(processExitsWith:)) inherits this environment and dies without atexit:
    // it uses its parent's root, which the parent removes.
    if (getenv("LTM_TEST_ROOT")) {
        snprintf(home, sizeof home, "%s", getenv("HOME"));
        return;
    }
    const char *tmp = getenv("TMPDIR");
    snprintf(root, sizeof root, "%s/ltm-tests-XXXXXX", tmp && *tmp ? tmp : "/tmp");
    if (!mkdtemp(root)) {
        perror("ltm tests: mkdtemp");
        abort();
    }
    char state[PATH_MAX], library[PATH_MAX];
    snprintf(home, sizeof home, "%s/home", root);
    snprintf(library, sizeof library, "%s/Library", home);
    snprintf(state, sizeof state, "%s/state", root);
    if (mkdir(home, 0700) || mkdir(library, 0700)) {
        perror("ltm tests: mkdir");
        abort();
    }
    setenv("CFFIXED_USER_HOME", home, 1);
    setenv("HOME", home, 1);
    setenv("LTM_STATE_DIR", state, 1);
    setenv("LTM_TEST_ROOT", root, 1);
    atexit(cleanup);
}

const char *ltm_test_home(void) { return home; }
