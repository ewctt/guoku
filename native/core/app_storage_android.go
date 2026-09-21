//go:build android

package core

import (
	"os"
	"path/filepath"
)

const androidDefaultDownloadDir = "/storage/emulated/0/Download/真果鉴"

func nativeDefaultDownloadLocation(directory string) string {
	if info, err := os.Stat(androidDefaultDownloadDir); err == nil && info.IsDir() {
		return androidDefaultDownloadDir
	}
	parent := filepath.Dir(androidDefaultDownloadDir)
	if info, err := os.Stat(parent); err == nil && info.IsDir() {
		if err := os.MkdirAll(androidDefaultDownloadDir, 0755); err == nil {
			return androidDefaultDownloadDir
		}
	}
	return filepath.Join(directory, "downloads")
}

func nativeDownloadFolderName() string {
	return "真果鉴"
}
