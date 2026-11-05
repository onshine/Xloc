APP_NAME    := Xloc
SCHEME      := Xloc
BUILD_DIR   := build
CONFIG      := Release
ENTITLEMENTS:= Xloc/Xloc.entitlements

.PHONY: all project build tipa clean deps

all: tipa

deps:
	@command -v xcodegen >/dev/null || (echo "安装 XcodeGen: brew install xcodegen"; exit 1)
	@command -v ldid >/dev/null || (echo "安装 ldid: brew install ldid-procursus"; exit 1)

project: deps
	xcodegen generate

build: project
	xcodebuild -project $(APP_NAME).xcodeproj \
		-scheme $(SCHEME) \
		-configuration $(CONFIG) \
		-sdk iphoneos \
		-derivedDataPath $(BUILD_DIR) \
		CODE_SIGNING_ALLOWED=NO \
		build

tipa: build
	@APP=$$(find $(BUILD_DIR)/Build/Products/$(CONFIG)-iphoneos -maxdepth 1 -name "*.app" | head -1); \
	echo "==> $$APP"; \
	./Scripts/package.sh "$$APP" "$(APP_NAME).tipa"

clean:
	rm -rf $(BUILD_DIR) $(APP_NAME).xcodeproj $(APP_NAME).tipa
