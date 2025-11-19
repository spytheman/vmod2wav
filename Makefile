.PHONY: convert clean play

all: vv.wav

clean:
	rm -rf mod2wav.exe vv.wav
	
mod2wav.exe: main.v
	v -keepc -cg -cc gcc-11 -o mod2wav.exe main.v

vv.wav: mod2wav.exe Tinytune.mod
	./mod2wav.exe ./Tinytune.mod vv.wav

play: vv.wav
	mplayer vv.wav
