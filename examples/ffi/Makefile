LDFLAGS := -shared -Wall -Wextra -O2
UNAME := $(shell uname -s)
ifeq ($(UNAME), Darwin)
	LDFLAGS += -undefined dynamic_lookup -target arm64-apple-macos11
endif

all: examples.so regex.so

%.so: %.c
	clang $(LDFLAGS) -o $@ $^

clean:
	rm -f *.so *.dylib
