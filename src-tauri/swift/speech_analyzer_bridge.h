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

int  apple_speech_available(void);
int  apple_speech_locale_installed(const char *lang);
AppleSpeechResult *apple_speech_install_locale(const char *lang);
AppleSpeechResult *apple_speech_transcribe(const float *samples, size_t len, const char *lang);
char *apple_speech_supported_locales_json(void); // JSON array of BCP-47 strings; free via apple_speech_free_str
void  apple_speech_free(AppleSpeechResult *result);
void  apple_speech_free_str(char *s);

#ifdef __cplusplus
}
#endif

#endif
