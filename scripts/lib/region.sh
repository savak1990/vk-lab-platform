# Neither region self-discovers via SSM: the parameter recording a region
# lives in that region, so querying it at a guessed region can't tell
# "not written yet" apart from "wrong region". Plain env-var defaults only.

ACCOUNT_MAIN_REGION="${ACCOUNT_MAIN_REGION:-eu-west-1}"
PROJECT_REGION="${PROJECT_REGION:-eu-west-1}"
