# What Sesam needs beyond the shared Makefile (oss-kit, templates/shared/swift).
CLI := yes

install::
	open "$(PREFIX)/$(NAME).app"

# Sesam writes one file (the frecency counts) and holds no daemon. The
# Accessibility grant is keyed to the code identity and goes with the binary.
uninstall::
	rm -rf "$(HOME)/Library/Application Support/Sesam"
