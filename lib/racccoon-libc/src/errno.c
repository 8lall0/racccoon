#include <errno.h>
#include <stddef.h>

int errno = 0;

/* Compact strerror — the common cases by name, everything else as
 * "error <n>" in a static buffer. Single-threaded, so the buffer and
 * strerror_r sharing storage is fine. */
static char strerr_buf[24];

char *strerror(int e)
{
	const char *s = NULL;
	switch (e) {
	case 0:            s = "Success"; break;
	case EPERM:        s = "Operation not permitted"; break;
	case ENOENT:      s = "No such file or directory"; break;
	case ESRCH:       s = "No such process"; break;
	case EINTR:       s = "Interrupted system call"; break;
	case EIO:         s = "Input/output error"; break;
	case E2BIG:       s = "Argument list too long"; break;
	case ENOEXEC:     s = "Exec format error"; break;
	case EBADF:       s = "Bad file descriptor"; break;
	case ECHILD:      s = "No child processes"; break;
	case EAGAIN:      s = "Resource temporarily unavailable"; break;
	case ENOMEM:      s = "Cannot allocate memory"; break;
	case EACCES:      s = "Permission denied"; break;
	case EFAULT:      s = "Bad address"; break;
	case EBUSY:       s = "Device or resource busy"; break;
	case EEXIST:      s = "File exists"; break;
	case EXDEV:       s = "Invalid cross-device link"; break;
	case ENOTDIR:     s = "Not a directory"; break;
	case EISDIR:      s = "Is a directory"; break;
	case EINVAL:      s = "Invalid argument"; break;
	case EMFILE:      s = "Too many open files"; break;
	case ENOTTY:      s = "Inappropriate ioctl for device"; break;
	case ENOSPC:      s = "No space left on device"; break;
	case ESPIPE:      s = "Illegal seek"; break;
	case EROFS:       s = "Read-only file system"; break;
	case EPIPE:       s = "Broken pipe"; break;
	case ERANGE:      s = "Numerical result out of range"; break;
	case ENAMETOOLONG:s = "File name too long"; break;
	case ENOSYS:      s = "Function not implemented"; break;
	case ENOTEMPTY:   s = "Directory not empty"; break;
	case ELOOP:       s = "Too many levels of symbolic links"; break;
	}
	if (s) return (char *)s;

	/* "error N" */
	char *p = strerr_buf;
	const char *pre = "error ";
	while (*pre) *p++ = *pre++;
	if (e < 0) { *p++ = '-'; e = -e; }
	char d[12]; int n = 0;
	do { d[n++] = (char)('0' + e % 10); e /= 10; } while (e);
	while (n) *p++ = d[--n];
	*p = 0;
	return strerr_buf;
}

int strerror_r(int e, char *buf, size_t n)
{
	char *s = strerror(e);
	size_t i = 0;
	while (s[i] && i + 1 < n) { buf[i] = s[i]; i++; }
	if (n) buf[i] = 0;
	return 0;
}
