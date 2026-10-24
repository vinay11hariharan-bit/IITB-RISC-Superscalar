# GHDL flow.  `make test` builds everything and runs the regression.
GHDL   ?= ghdl
FLAGS  := --std=08 --workdir=build
SRCS   := $(shell cat files.txt) tb/tb_superscalar.vhd

.PHONY: build test random clean

build:
	@mkdir -p build
	@for f in $(SRCS); do $(GHDL) -a $(FLAGS) $$f || exit 1; done
	@cd build && $(GHDL) -e --std=08 --workdir=. tb_superscalar

test:
	python3 tools/run_tests.py

random:
	python3 tools/run_tests.py --random 2000

clean:
	rm -rf build
