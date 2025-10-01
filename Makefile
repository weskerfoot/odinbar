build:
	odin build .

debug:
	odin build . -debug -sanitize:address

run:
	make build
	./odinbar

test:
	odin test .
