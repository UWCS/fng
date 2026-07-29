#!/bin/bash

if [ -f ~/.config/containers/storage.conf ]; then
    echo "Skipped: ~/.config/containers/storage.conf already exists"
else
    mkdir -p ~/.config/containers
    cp ./host/storage.conf ~/.config/containers/storage.conf
fi

if [ -f ~/.xsession ]; then
    echo "Skipped: ~/.xsession already exists"
else
    target=$(dirname "$(readlink -f '$0')")
    echo -e "#!/bin/bash\ncd ${target}\n./host/.xsession" > ~/.xsession
    chmod +x ~/.xsession
fi

echo "Done"