//go:build plan9

package main

import (
	"io"
	"os"
)

type uiFS struct{ root string }

func openUI() (*uiFS, error) {
	r := os.Getenv("ui")
	if r == "" {
		r = "/mnt/ui"
	}
	return &uiFS{r}, nil
}

func (u *uiFS) Open(path string, write bool) (io.ReadWriter, error) {
	if write {
		return os.OpenFile(u.root+"/"+path, os.O_WRONLY, 0)
	}
	return os.Open(u.root + "/" + path)
}
