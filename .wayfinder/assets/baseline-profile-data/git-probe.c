// git-probe: 记录 CLOCK_MONOTONIC ns 时间戳 + 完整 argv(tab 分隔)后 exec 真 git
// 用 C 而非 bash 包装,避免给每次 spawn 引入额外 shell 启动开销(测量偏置)
#define _GNU_SOURCE
#include <stdio.h>
#include <stdlib.h>
#include <time.h>
#include <unistd.h>

int main(int argc, char **argv) {
  const char *log = getenv("GIT_PROBE_LOG");
  if (!log || !*log)
    log = "/tmp/opencode/git-probe.log";
  FILE *f = fopen(log, "a");
  if (f) {
    struct timespec ts;
    clock_gettime(CLOCK_MONOTONIC, &ts);
    fprintf(f, "%lld.%09ld", (long long)ts.tv_sec, ts.tv_nsec);
    for (int i = 1; i < argc; i++)
      fprintf(f, "\t%s", argv[i]);
    fprintf(f, "\n");
    fclose(f);
  }
  char **nargv = malloc(sizeof(char *) * (argc + 1));
  if (!nargv)
    return 126;
  nargv[0] = (char *)"/usr/bin/git";
  for (int i = 1; i < argc; i++)
    nargv[i] = argv[i];
  nargv[argc] = NULL;
  execv("/usr/bin/git", nargv);
  perror("execv");
  return 127;
}
