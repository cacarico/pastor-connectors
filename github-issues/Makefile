SCRIPTS = poll.sh finish.sh test/run.sh test/bin/gh

.PHONY: check
check:
	for s in $(SCRIPTS); do sh -n $$s || exit 1; done
	sh test/run.sh
