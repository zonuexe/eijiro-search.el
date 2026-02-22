EMACS ?= emacs
EASK ?= eask

all: autoloads install compile lint

install:
	$(EASK) install

autoloads:
	$(EASK) generate autoloads

compile:
	$(EASK) compile

clean:
	$(EASK) clean all

test: clean all
	$(EASK) test ert ./test/eijiro-search-test.el

lint: checkdoc check-declare

checkdoc:
	$(EASK) lint checkdoc

check-declare:
	$(EASK) lint declare

qa: lint test

.PHONY: all autoloads checkdoc check-declare clean compile install lint qa test
