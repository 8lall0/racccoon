// C++ on racccoon (lib/racccoon-libc/build_cxx.sh): static libc++ /
// libc++abi over racccoon-libc, no exceptions / RTTI / threads — the
// subset LLVM itself builds with. Run by the shell's `cxxtest` builtin;
// exit code 0 only if every check passed. The last line ("dtor ran")
// comes from a global destructor, after main has returned.
#include <algorithm>
#include <cstdio>
#include <functional>
#include <map>
#include <memory>
#include <optional>
#include <string>
#include <string_view>
#include <unordered_map>
#include <variant>
#include <vector>

static int pass, total;

static void check(const char *what, bool ok)
{
	total++;
	if (ok) pass++;
	std::printf("cxxtest: %s: %s\n", what, ok ? "ok" : "FAILED");
}

// Static construction before main, destruction after it.
struct Global {
	int value;
	Global() : value(42) {}
	~Global() { std::printf("cxxtest: dtor ran\n"); }
};
static Global global;

static int counter_calls;
static int &counter()
{
	static int n = ++counter_calls;   // initialised exactly once
	return n;
}

struct Base {
	virtual ~Base() {}
	virtual int f() const { return 1; }
};
static int derived_dtors;
struct Derived : Base {
	~Derived() override { derived_dtors++; }
	int f() const override { return 2; }
};

struct alignas(64) Wide { char bytes[64]; };

int main()
{
	check("static constructor ran before main", global.value == 42);

	counter(); counter(); counter();
	check("function-local static initialised once", counter_calls == 1);

	std::string s = "rac";
	s += "ccoon";
	s += std::to_string(2026);
	check("std::string + to_string", s == "racccoon2026");

	std::vector<int> v;
	for (int i = 0; i < 10000; i++) v.push_back((i * 7919) % 10007);
	std::sort(v.begin(), v.end());
	check("vector of 10000 + sort", v.size() == 10000 && std::is_sorted(v.begin(), v.end()));

	std::map<std::string, int> m;
	std::unordered_map<int, std::string> um;
	for (int i = 0; i < 500; i++) {
		m["k" + std::to_string(i)] = i;
		um[i] = std::to_string(i * i);
	}
	check("map / unordered_map", m.size() == 500 && m["k123"] == 123 && um[12] == "144");

	{
		std::unique_ptr<Base> p = std::make_unique<Derived>();
		check("virtual dispatch", p->f() == 2);
	}
	check("virtual destructor via unique_ptr", derived_dtors == 1);

	int captured = 5;
	std::function<int(int)> fn = [captured](int x) { return x * captured; };
	check("std::function + capturing lambda", fn(8) == 40);

	Wide *w = new Wide;
	bool aligned = ((unsigned long)w % 64) == 0;
	delete w;
	check("aligned operator new (alignas 64)", aligned);

	std::optional<int> o = 3;
	std::variant<int, std::string_view> var = std::string_view("hello");
	check("optional / variant / string_view",
	      o.value_or(0) == 3 && std::get<std::string_view>(var).size() == 5);

	std::printf("cxxtest: %d/%d\n", pass, total);
	return pass == total ? 0 : 1;
}
