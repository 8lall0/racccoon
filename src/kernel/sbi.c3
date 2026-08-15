module sbi;

struct Sbiret
{
	long error;
	long value;
}

fn Sbiret sbi_call(long arg0, long arg1, long arg2, long arg3, long arg4, long arg5, long fid, long eid)
{
	Sbiret output;
	long error;
	long value;

	asm
	{
		mv $a0, arg0;
		mv $a1, arg1;
		mv $a2, arg2;
		mv $a3, arg3;
		mv $a4, arg4;
		mv $a5, arg5;
		mv $a6, fid;
		mv $a7, eid;

		ecall;

		sd $a0, [&error];
		sd $a1, [&value];
	}

	output.value = value;
	output.error = error;

	return output;
}

fn int __putchar(int ch)
{
	sbi_call((long)ch, 0, 0, 0, 0, 0, 0, 1);
	return ch;
}

fn int __getchar()
{
	Sbiret ret = sbi_call(0, 0, 0, 0, 0, 0, 0, 2);
	return (int)ret.error;
}