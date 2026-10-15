# usage: hx.sh <host> <script-file>   - copy a script to the rehearsal host and run it there (stdin detached)
export MSYS_NO_PATHCONV=1
docker exec -i "$1" sh -c 'cat > /tmp/hx-script.sh' < "$2"
docker exec "$1" bash /tmp/hx-script.sh < /dev/null
