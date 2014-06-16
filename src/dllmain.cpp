#include <tdebuglistener.h>
#include <windows.h>

// Redirect the debug messages to Windows debugger.

#ifdef _DEBUG

namespace TagLib_Nuget
{
    class DebugListner : public TagLib::DebugListener
    {
        virtual void printMessage(const TagLib::String &msg)
        {
            ::OutputDebugStringW(msg.toCWString());
        }
    };

    DebugListner listener;
}

#endif

BOOL APIENTRY DllMain(HMODULE, DWORD  ul_reason_for_call, LPVOID)
{
#ifdef _DEBUG
    switch (ul_reason_for_call)
    {
    case DLL_PROCESS_ATTACH:
        TagLib::setDebugListener(&TagLib_Nuget::listener);
        break;
    case DLL_THREAD_ATTACH:
        break;
    case DLL_THREAD_DETACH:
        break;
    case DLL_PROCESS_DETACH:
        TagLib::setDebugListener(NULL);
        break;
    }
#endif
    return TRUE;
}
