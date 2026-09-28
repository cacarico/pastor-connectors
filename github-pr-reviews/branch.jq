# Jobs and orchestrators put branch names in prompts an agent may run as
# shell commands. Only names made of these characters are passed on; the
# rest are skipped.
def safe_branch:
  test("^[A-Za-z0-9_./-]+$") and (startswith("-") | not) and (contains("..") | not);
