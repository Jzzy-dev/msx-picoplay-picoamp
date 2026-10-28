#ifndef PICOVERSEAUDIO_HH
#define PICOVERSEAUDIO_HH

// PicoVerse Audio Engine (test device).
// Runs the real engine code (host build, libpva_host.a) behind the register
// window at 4000h-4FFFh of the device's slot. Engine time follows emulated
// time: core 1 is polled once per emulated millisecond.

#include "MSXDevice.hh"
#include "Schedulable.hh"
#include "EmuTime.hh"

namespace openmsx {

class PicoVerseAudio final : public MSXDevice, private Schedulable
{
public:
	explicit PicoVerseAudio(const DeviceConfig& config);
	~PicoVerseAudio() override;

	void reset(EmuTime::param time) override;
	[[nodiscard]] byte readMem(word address, EmuTime::param time) override;
	[[nodiscard]] byte peekMem(word address, EmuTime::param time) const override;
	void writeMem(word address, byte value, EmuTime::param time) override;
	[[nodiscard]] const byte* getReadCacheLine(word start) const override;
	[[nodiscard]] byte* getWriteCacheLine(word start) const override;

	template<typename Archive>
	void serialize(Archive& ar, unsigned version);

private:
	void executeUntil(EmuTime::param time) override;
	void catchUp(EmuTime::param time);

	EmuTime last;
	bool started = false;
};

} // namespace openmsx

#endif
