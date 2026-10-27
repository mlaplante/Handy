#ifndef SPEECH_ANALYZER_BRIDGE_H
#define SPEECH_ANALYZER_BRIDGE_H
#include <stddef.h>

#ifdef __cplusplus
extern "C" {
#endif

typedef struct {
    char *text;           // owned; free via apple_speech_free
    int   success;        // 1 = ok, 0 = error
    char *error_message;  // owned; free via apple_speech_free
} AppleSpeechResult;

// Check if Apple SpeechAnalyzer/SpeechTranscriber is available on this OS
int  apple_speech_available(void);
// Check if the given BCP-47 locale's on-device assets are installed
int  apple_speech_locale_installed(const char *lang);
// Install the given BCP-47 locale's on-device assets, blocking until done
AppleSpeechResult *apple_speech_install_locale(const char *lang);
// Transcribe 16kHz mono f32 samples in the given BCP-47 locale
AppleSpeechResult *apple_speech_transcribe(const float *samples, size_t len, const char *lang);
// JSON array of BCP-47 strings; free via apple_speech_free_str
char *apple_speech_supported_locales_json(void);
// Free memory allocated for an AppleSpeechResult
void  apple_speech_free(AppleSpeechResult *result);
// Free a string allocated by apple_speech_supported_locales_json
void  apple_speech_free_str(char *s);

#ifdef __cplusplus
}
#endif

#endif
