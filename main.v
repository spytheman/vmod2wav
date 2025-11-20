module main

import os

const sample_rate = 44100
const tick_samples = i32(sample_rate / 57.4) // TODO: implement a proper speed change support, instead of tweaking this

const sine_table = [i32(0), 24, 49, 74, 97, 120, 141, 161, 180, 197, 212, 224, 235, 244, 250, 253,
	255, 253, 250, 244, 235, 224, 212, 197, 180, 161, 141, 120, 97, 74, 49, 24]!

struct Sample {
mut:
	name          [22]byte
	length        u16
	finetune      i8
	volume        u8
	repeat_start  u16
	repeat_length u16
}

struct Channel {
mut:
	pos           u32
	step          u32
	target_step   u32
	sample        u8
	volume        u8
	data          &u8 = unsafe { nil }
	length        u32
	loop_start    u32
	loop_len      u32
	period        u16
	effect        u8
	param         u8
	porta_speed   i16
	vibrato_pos   u8
	vibrato_speed u8
	vibrato_depth u8
	tremolo_pos   u8
	tremolo_speed u8
	tremolo_depth u8
}

@[inline]
fn (mut ch Channel) limit_volume() {
	if ch.param & 0xF0 != 0 {
		ch.volume += (ch.param >> 4)
	} else {
		ch.volume -= (ch.param & 0x0F)
	}
	if ch.volume > 64 {
		ch.volume = if ch.volume > 200 { u8(0) } else { 64 }
	}
}

fn write_wav_header(mut f os.File, data_size u32) ! {
	channels := u16(2)
	bits := u16(16)
	chunk_size := u32(36 + data_size)
	rate := u32(sample_rate)
	byte_rate := u32(rate * u32(channels) * u32(bits) / 8)
	block_align := u16(channels * bits / 8)
	f.write_string('RIFF')!
	f.write_le(chunk_size)!
	f.write_string('WAVE')!
	f.write_string('fmt ')!
	f.write_le[u32](16)! // block size = chunk size - 8
	f.write_le[u16](1)! // audio format 1 = PCM integer
	f.write_le(channels)! // channels
	f.write_le(rate)!
	f.write_le(byte_rate)!
	f.write_le(block_align)!
	f.write_le(bits)!
	f.write_string('data')!
	f.write_le(data_size)!
}

@[inline]
fn clamp[T](min T, val T, max T) T {
	return if val < min {
		min
	} else {
		if val > max {
			max
		} else {
			val
		}
	}
}

@[inline]
fn period_to_step(period u16) u32 {
	return if period == 0 {
		u32(0)
	} else {
		u32((f64(3546895.0) / f64(period) / sample_rate) * 65536.0)
	}
}

fn process_effects(mut ch Channel, tick int) {
	if tick == 0 {
		return
	}
	match ch.effect {
		0x0 {
			// Arpeggio
			if ch.param != 0 {
				mut note := 0
				match tick % 3 {
					1 { note = int(ch.param >> 4) }
					2 { note = int(ch.param & 0x0F) }
					else { note = 0 }
				}
				if note != 0 && ch.period != 0 {
					mut factor := 1.0
					for i := 0; i < note; i++ {
						factor *= 1.059463094359
					}
					ch.step = period_to_step(u16(f64(ch.period) / factor))
				}
			}
		}
		0x1 {
			// Portamento up
			if ch.period > ch.param {
				ch.period -= ch.param
				ch.step = period_to_step(ch.period)
			}
		}
		0x2 {
			// Portamento down
			if ch.period + ch.param < 856 {
				ch.period += ch.param
				ch.step = period_to_step(ch.period)
			}
		}
		0x3 {
			// Tone portamento
			if ch.porta_speed != 0 {
				if ch.period < ch.target_step {
					ch.period += u16(ch.porta_speed)
					if ch.period > ch.target_step {
						ch.period = u16(ch.target_step)
					}
				} else if ch.period > ch.target_step {
					ch.period -= u16(ch.porta_speed)
					if ch.period < ch.target_step {
						ch.period = u16(ch.target_step)
					}
				}
				ch.step = period_to_step(ch.period)
			}
		}
		0x4 {
			// Vibrato
			if ch.vibrato_speed != 0 && ch.vibrato_depth != 0 {
				delta := (sine_table[ch.vibrato_pos] * int(ch.vibrato_depth)) / 128
				ch.step = period_to_step(u16(int(ch.period) + delta))
				ch.vibrato_pos = (ch.vibrato_pos + ch.vibrato_speed) & 31
			}
		}
		0x5 {
			// Tone portamento + volume slide; Porta handled above
			ch.limit_volume()
		}
		0x6 {
			// Vibrato + volume slide; Vibrato handled above
			ch.limit_volume()
		}
		0x7 {
			// Tremolo
			if ch.tremolo_speed != 0 && ch.tremolo_depth != 0 {
				delta := (sine_table[ch.tremolo_pos] * int(ch.tremolo_depth)) / 64
				mut vol := int(ch.volume) + delta
				vol = clamp(0, vol, 64)
				ch.volume = u8(vol)
				ch.tremolo_pos = (ch.tremolo_pos + ch.tremolo_speed) & 31
			}
		}
		0xA {
			// Volume slide
			ch.limit_volume()
		}
		0xE {
			// Extended effects
			match ch.param >> 4 {
				0x9 {
					// Retrigger note
					if (ch.param & 0x0F) != 0 && (tick % int(ch.param & 0x0F)) == 0 {
						ch.pos = 0
					}
				}
				0xC {
					// Note cut
					if tick == int(ch.param & 0x0F) {
						ch.volume = 0
					}
				}
				0xD {
					// Note delay
					if tick == int(ch.param & 0x0F) {
						ch.pos = 0
					}
				}
				else {}
			}
		}
		else {}
	}
}

fn main() {
	if os.args.len != 3 {
		eprintln('Usage: ${os.args[0]} input.mod output.wav')
		exit(1)
	}
	mut in_file := os.open(os.args[1]) or {
		eprintln('Input file error: ${err}')
		exit(1)
	}
	mut title := [20]u8{}
	mut samples := [31]Sample{}
	in_file.read_into_ptr(&title[0], 20)!
	println('MOD title: ${unsafe { cstring_to_vstring(&title[0]) }}')
	unsafe {
		for i in 0 .. samples.len {
			in_file.read_into_ptr(&u8(&samples[i].name), 22)!
			samples[i].length = in_file.read_be[u16]()! * 2
			in_file.read_into_ptr(u8(&samples[i].finetune), 1)!
			in_file.read_into_ptr(&samples[i].volume, 1)!
			samples[i].repeat_start = in_file.read_be[u16]()! * 2
			samples[i].repeat_length = in_file.read_be[u16]()! * 2
		}
	}
	mut song_length := u8(0)
	mut restart := u8(0)
	in_file.read_into_ptr(&song_length, 1)!
	in_file.read_into_ptr(&restart, 1)!

	mut pattern_table := [128]u8{}
	in_file.read_into_ptr(&pattern_table[0], 128)!
	fourcc := [4]u8{}
	in_file.read_into_ptr(&fourcc[0], 4)!
	println('FOURCC: ${fourcc[..].bytestr()}')

	mut max_pattern := u8(0)
	for i in 0 .. 128 {
		if pattern_table[i] > max_pattern {
			max_pattern = pattern_table[i]
		}
	}

	max_pattern_size := int(max_pattern + 1) * 1024
	mut patterns := unsafe { &u8(malloc(max_pattern_size)) }
	in_file.read_into_ptr(patterns, max_pattern_size)!

	mut sample_data := []&u8{len: 31, init: unsafe { nil }}
	for i in 0 .. 31 {
		sample_data[i] = unsafe { &u8(malloc(int(samples[i].length))) }
		in_file.read_into_ptr(sample_data[i], int(samples[i].length))!
	}
	in_file.close()
	//////////////////////////////////////////////////////////
	mut out_file := os.create(os.args[2]) or {
		eprintln('Output file error: ${err}')
		exit(1)
	}
	out_file.seek(44, .start)!
	mut ch := [Channel{}, Channel{}, Channel{}, Channel{}]!
	mut samples_written := u32(0)
	mut speed := 6
	for ord in 0 .. int(song_length) {
		pat_data := unsafe { patterns + int(pattern_table[ord]) * 1024 }
		for row in 0 .. 64 {
			for c in 0 .. 4 {
				note := unsafe { pat_data + row * 16 + c * 4 }
				period := unsafe { (u16(note[0] & 0x0F) << 8) | u16(note[1]) }
				sample := unsafe { (note[0] & 0xF0) | ((note[2] & 0xF0) >> 4) }
				effect := unsafe { note[2] & 0x0F }
				param := unsafe { note[3] }
				ch[c].effect = effect
				ch[c].param = param
				if sample > 0 && sample <= 31 {
					ch[c].sample = sample - 1
					dsample := samples[ch[c].sample]
					ch[c].volume = dsample.volume
					ch[c].data = sample_data[ch[c].sample]
					ch[c].length = u32(dsample.length)
					ch[c].loop_start = u32(dsample.repeat_start)
					ch[c].loop_len = u32(dsample.repeat_length)
					if ch[c].loop_len <= 2 {
						ch[c].loop_len = 0
					}
					if effect != 0x3 && effect != 0x5 {
						ch[c].pos = 0
					}
				}
				if period > 0 {
					if effect == 0x3 || effect == 0x5 {
						ch[c].target_step = u32(period)
						if param != 0 {
							ch[c].porta_speed = i16(param)
						}
					} else {
						ch[c].period = period
						ch[c].step = period_to_step(period)
						ch[c].pos = 0
					}
				}
				if effect == 0x4 || effect == 0x6 {
					if param != 0 {
						if param & 0x0F != 0 {
							ch[c].vibrato_depth = param & 0x0F
						}
						if param & 0xF0 != 0 {
							ch[c].vibrato_speed = param >> 4
						}
					}
				}
				if effect == 0x7 {
					if param != 0 {
						if param & 0x0F != 0 {
							ch[c].tremolo_depth = param & 0x0F
						}
						if param & 0xF0 != 0 {
							ch[c].tremolo_speed = param >> 4
						}
					}
				}
				if effect == 0xC {
					ch[c].volume = u8(clamp(0, param, 64))
				}
				if effect == 0xF && param < 32 {
					speed = int(param)
				}
			}
			for tick in 0 .. speed {
				for c in 0 .. 4 {
					process_effects(mut ch[c], tick)
				}
				for _ in 0 .. tick_samples {
					mut left := i32(0)
					mut right := i32(0)
					for c in 0 .. 4 {
						if ch[c].data != 0 && ch[c].step > 0 {
							idx := ch[c].pos >> 16
							if idx < ch[c].length {
								val := unsafe { i8(ch[c].data[idx]) * i16(ch[c].volume) }
								if c & 1 != 0 {
									right += i32(val)
								} else {
									left += i32(val)
								}

								ch[c].pos += ch[c].step

								if (ch[c].pos >> 16) >= ch[c].length {
									if ch[c].loop_len > 0 {
										ch[c].pos = ch[c].loop_start << 16
										ch[c].length = ch[c].loop_start + ch[c].loop_len
									} else {
										ch[c].step = 0
									}
								}
							}
						}
					}
					out_left := i16(clamp(-32768, left, 32767))
					out_right := i16(clamp(-32768, right, 32767))
					out_file.write_le(out_left)!
					out_file.write_le(out_right)!
					samples_written += 4
				}
			}
		}
	}
	out_file.seek(0, .start)!
	write_wav_header(mut out_file, samples_written)!
	out_file.close()
	unsafe {
		free(patterns)
		for i in 0 .. 31 {
			free(sample_data[i])
		}
		sample_data.free()
	}
	println('Converted: ${os.args[1]} -> ${os.args[2]}')
}
