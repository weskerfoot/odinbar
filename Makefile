build:
	odin build .

debug:
	odin build . -debug

run:
	make build
	./odinbar

test:
	odin test .
