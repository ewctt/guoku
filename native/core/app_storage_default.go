//go:build !android

package core

import "path/filepath"

func nativeDefaultDownloadLocation(directory string) string {
	return filepath.Join(directory, "downloads")
}

func nativeDownloadFolderName() string {
	return "zhenguojian-downloads"
}
