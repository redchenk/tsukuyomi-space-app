/* Start an isolated POSIX process group so cancellation includes shell children. */
#include <unistd.h>
#include <stdio.h>
#include <errno.h>
#include <string.h>
int main(int argc, char **argv) {
  if (argc < 2) return 64;
  if (setsid() == -1) {
    fprintf(stderr, "Cannot create command process group: %s\n", strerror(errno));
    return 70;
  }
  execv(argv[1], argv + 1);
  fprintf(stderr, "Cannot start command sandbox: %s\n", strerror(errno));
  return 71;
}
