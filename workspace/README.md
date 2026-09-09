# Workspace

This directory is mounted into the container at `/workspace` and is the only
part of your machine the file tools can see when running under Docker.

Point `CLAUDEX_CHAT_WORKSPACE` at a different directory to give Claude access
to a real project instead — it gets read and write access there, subject to
your approval on every individual call.
