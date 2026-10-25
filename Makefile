.PHONY: app run install selftest icon clean

app:
	./Scripts/build-app.sh

icon:
	./Scripts/make-icon.sh

run: app
	open dist/Sentinel.app

install: app
	rm -rf /Applications/Sentinel.app
	cp -R dist/Sentinel.app /Applications/
	open /Applications/Sentinel.app

selftest:
	swift run -c release Sentinel --selftest

clean:
	rm -rf .build dist
