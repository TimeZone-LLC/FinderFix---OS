.PHONY: build test app app-universal release run clean

build:
	swift build

test:
	swift test

app:
	FINDERFIX_BUILD_PURPOSE=development ./Scripts/build-app.sh release

app-universal:
	FINDERFIX_BUILD_PURPOSE=development FINDERFIX_UNIVERSAL=1 ./Scripts/build-app.sh release

release:
	./Scripts/release-app.sh

run: app
	open .build/app/FinderFix.app

clean:
	swift package clean
