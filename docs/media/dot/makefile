SHELL := /usr/bin/env bash

# dot, neato, twopi, circo, fdp, sfdp, patchwork, osage
DOT ?= dot

FONT ?= "TeX Gyre Schola"

DOTs = $(wildcard *.dot)
SVGs = $(patsubst %.dot,%.svg,$(DOTs))

all: $(SVGs)

%.svg: %.dot
	$(DOT) -T svg:cairo $< -o $@ -Nfontname=$(FONT) -Efontname=$(FONT) -Gfontname=$(FONT)

clean:
	rm -f $(SVGs)

print-%:
	$(info $* = $($*))
