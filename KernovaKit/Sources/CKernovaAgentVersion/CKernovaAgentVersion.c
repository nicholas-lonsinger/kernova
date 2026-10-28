#include "CKernovaAgentVersion.h"

// Tools/build-linux-guest-agent.sh writes this header into a directory it adds
// to the include path, so only this file depends on the label: a label passed
// as a -D flag would change every module's command line and rebuild them all.
#if __has_include("KernovaAgentVersionLabel.h")
#include "KernovaAgentVersionLabel.h"
#endif

#ifndef KERNOVA_AGENT_VERSION_LABEL
#define KERNOVA_AGENT_VERSION_LABEL "development"
#endif

const char *kernova_agent_version_label(void) {
    return KERNOVA_AGENT_VERSION_LABEL;
}
