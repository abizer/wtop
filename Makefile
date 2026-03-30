PREFIX ?= /usr/local

.PHONY: build install uninstall clean

build:
	swift build -c release --disable-sandbox

install: build
	install -d $(PREFIX)/bin
	install -m 755 .build/release/wtop $(PREFIX)/bin/wtop

uninstall:
	rm -f $(PREFIX)/bin/wtop

clean:
	swift package clean
	rm -rf .build
