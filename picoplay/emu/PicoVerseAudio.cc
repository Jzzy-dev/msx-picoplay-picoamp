#include <cstdlib>
#include <cstdio>
#include "PicoVerseAudio.hh"
#include "DeviceConfig.hh"
#include "MSXException.hh"
#include "serialize.hh"
#include <cstdio>
#include <string>

extern "C" {
#include <stdint.h>
#include <stddef.h>
#include <stdbool.h>
void pva_init(uint8_t* arena, size_t arena_size);
uint8_t pva_mem_read(uint16_t addr);
void pva_mem_write(uint16_t addr, uint8_t data);
void pva_core1_init(void);
bool pva_core1_poll(void);
int  host_esp_load_audio(const char *mp3_path);
extern uint32_t host_audio_frames, host_audio_underruns;
int  host_disk_open(const char* path, uint32_t create_sectors);
void host_advance_ms(uint32_t ms);
void host_wav_open(const char* path);
void host_wav_close(void);
extern bool host_audio_unlimited;
extern uint32_t host_audio_underruns;
}

namespace openmsx {

static uint8_t arena[120 * 1024];     // as the firmware: 128 KB minus the 8 KB core 1 stack

PicoVerseAudio::PicoVerseAudio(const DeviceConfig& config)
	: MSXDevice(config)
	, Schedulable(MSXDevice::getScheduler())
	, last(Schedulable::getCurrentTime())
{
	std::string image(config.getChildData("image"));
	if (host_disk_open(image.c_str(), 0) != 0) {
		fprintf(stderr, "PicoVerseAudio: cannot open image %s\n", image.c_str());
	}
	std::string stream(config.getChildData("stream", ""));
	if (!stream.empty() && host_esp_load_audio(stream.c_str()) != 0) {
		fprintf(stderr, "PicoVerseAudio: cannot open stream source %s\n", stream.c_str());
	}
	std::string wav(config.getChildData("wav", ""));
	if (!wav.empty()) host_wav_open(wav.c_str());
	host_audio_unlimited = false;   // real-time I2S consumer
	pva_init(arena, sizeof arena);
	pva_core1_init();
	started = true;
	setSyncPoint(last + EmuDuration::msec(1));
}

PicoVerseAudio::~PicoVerseAudio()
{
	host_wav_close();
	fprintf(stderr, "PicoVerseAudio: underruns %u\n", host_audio_underruns);
}

void PicoVerseAudio::reset(EmuTime::param /*time*/)
{
}

void PicoVerseAudio::catchUp(EmuTime::param time)
{
	while (last + EmuDuration::msec(1) <= time) {
		last += EmuDuration::msec(1);
		pva_core1_poll();
		host_advance_ms(1);
		static int tr = getenv("PVA_TRACE") ? 1 : 0;
		static unsigned n;
		if (tr && ++n % 1000 == 0) {
			fprintf(stderr, "PVA t=%us state %u flags %02x el %u buf %u%% net %u rate %u frames %u underruns %u\n", n / 1000,
				pva_mem_read(0x4021), pva_mem_read(0x4022), pva_mem_read(0x4024) | (pva_mem_read(0x4025) << 8),
				pva_mem_read(0x4020 + 163), pva_mem_read(0x4020 + 162), pva_mem_read(0x4020 + 164) | (pva_mem_read(0x4020 + 165) << 8),
				host_audio_frames, host_audio_underruns);
		}
	}
}

void PicoVerseAudio::executeUntil(EmuTime::param time)
{
	catchUp(time);
	setSyncPoint(last + EmuDuration::msec(1));
}

byte PicoVerseAudio::readMem(word address, EmuTime::param time)
{
	catchUp(time);
	return pva_mem_read(address);
}

byte PicoVerseAudio::peekMem(word address, EmuTime::param /*time*/) const
{
	return pva_mem_read(address);
}

void PicoVerseAudio::writeMem(word address, byte value, EmuTime::param time)
{
	catchUp(time);
	pva_mem_write(address, value);
}

const byte* PicoVerseAudio::getReadCacheLine(word /*start*/) const { return nullptr; }
byte* PicoVerseAudio::getWriteCacheLine(word /*start*/) const { return nullptr; }

template<typename Archive>
void PicoVerseAudio::serialize(Archive& ar, unsigned /*version*/)
{
	ar.template serializeBase<MSXDevice>(*this);
}
INSTANTIATE_SERIALIZE_METHODS(PicoVerseAudio);
REGISTER_MSXDEVICE(PicoVerseAudio, "PicoVerseAudio");

} // namespace openmsx
