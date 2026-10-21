/* <dlfcn.h>: no dynamic loading on racccoon (static programs only). */
#include <dlfcn.h>

static char *dl_err;
static int self_handle;

void *dlopen(const char *file, int mode)
{
	(void)mode;
	if (!file) return &self_handle;
	dl_err = "dlopen: dynamic loading is not supported on racccoon";
	return 0;
}

void *dlsym(void *handle, const char *name)
{
	(void)handle; (void)name;
	dl_err = "dlsym: no dynamic symbol table (statically linked)";
	return 0;
}

int dlclose(void *handle) { (void)handle; return 0; }

char *dlerror(void)
{
	char *e = dl_err;
	dl_err = 0;
	return e;
}

int dladdr(const void *addr, Dl_info *info) { (void)addr; (void)info; return 0; }
