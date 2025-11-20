.PHONY: convert clean play

all: vv.wav

clean:
	rm -rf mod2wav.exe *.wav
	
mod2wav.exe: main.v
	v -o mod2wav.exe main.v

vv.wav: mod2wav.exe Tinytune.mod
	./mod2wav.exe ./Tinytune.mod vv.wav

play: vv.wav
	mplayer -really-quiet vv.wav

play_tetris: tetris.wav
	mplayer -really-quiet tetris.wav

tetris.wav: mod2wav.exe tetris.mod
	./mod2wav.exe ./tetris.mod tetris.wav
