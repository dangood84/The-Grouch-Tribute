# The Grouch Tribute — classic Empty Trash companion (Free Pascal)
#
# macOS:   make
# Linux:   sudo apt install fpc libgtk2.0-dev   &&  make linux
# Windows: from a native FPC install:            make windows

FPC      ?= fpc
SRC      := src
BUILD    := build
APP      := $(BUILD)/TheGrouch.app
UNITS    := -Fu$(SRC) -FU$(BUILD) -FE$(BUILD)
FLAGS    := -Mobjfpc -Scgi -O2 -Xs

.PHONY: all app run linux windows test snap clean

all: app

$(BUILD):
	mkdir -p $(BUILD)

$(BUILD)/TheGrouch: $(BUILD) $(SRC)/*.pas
	$(FPC) $(FLAGS) $(UNITS) -o$(BUILD)/TheGrouch $(SRC)/grouch.pas

$(BUILD)/grouchtest: $(BUILD) $(SRC)/ugrouchconfig.pas $(SRC)/ugrouchtrash.pas $(SRC)/ugrouchaudio.pas $(SRC)/ugrouchmodel.pas $(SRC)/ugrouchrender.pas $(SRC)/ugrouchapp.pas $(SRC)/grouchtest.pas
	$(FPC) $(FLAGS) $(UNITS) -o$(BUILD)/grouchtest $(SRC)/grouchtest.pas

$(BUILD)/grouchsnap: $(BUILD) $(SRC)/ugrouchconfig.pas $(SRC)/ugrouchtrash.pas $(SRC)/ugrouchaudio.pas $(SRC)/ugrouchmodel.pas $(SRC)/ugrouchrender.pas $(SRC)/ugrouchapp.pas $(SRC)/grouchsnap.pas
	$(FPC) $(FLAGS) $(UNITS) -o$(BUILD)/grouchsnap $(SRC)/grouchsnap.pas

app: $(BUILD)/TheGrouch
	mkdir -p $(APP)/Contents/MacOS $(APP)/Contents/Resources
	cp $(BUILD)/TheGrouch $(APP)/Contents/MacOS/TheGrouch
	cp bundle/Info.plist $(APP)/Contents/Info.plist

run: app
	open $(APP)

linux: $(BUILD)
	$(FPC) $(FLAGS) $(UNITS) -o$(BUILD)/thegrouch $(SRC)/grouch.pas

windows: $(BUILD)
	$(FPC) $(FLAGS) $(UNITS) -o$(BUILD)/TheGrouch.exe $(SRC)/grouch.pas

test: $(BUILD)/grouchtest
	$(BUILD)/grouchtest

snap: $(BUILD)/grouchsnap
	$(BUILD)/grouchsnap $(BUILD)

clean:
	rm -rf $(BUILD)
