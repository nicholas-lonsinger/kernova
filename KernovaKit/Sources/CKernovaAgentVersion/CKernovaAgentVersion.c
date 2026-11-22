#include "CKernovaAgentVersion.h"

// In an ELF build the label is the whole of its own section, which
// Tools/build-linux-guest-agent.sh rewrites in the built binary
// (stamp_linux_agent_label in Tools/lib/linux-agent.sh), so compiling the agent
// never depends on the label and one build serves every label.
#if defined(__ELF__)
__attribute__((used, section("kernova_agent_label")))
#endif
static const char label[64] = "development";

const char *kernova_agent_version_label(void) {
    return label;
}
