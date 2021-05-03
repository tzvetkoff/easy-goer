///usr/bin/env true; exec /usr/bin/env go run "$0" "$@"
package main

import (
	"fmt"
	"io/ioutil"
	"net/http"
	"os"
	"path/filepath"
	"regexp"
	"sort"
	"strconv"
	"strings"
)

const (
	red    = "\033[1;31m"
	green  = "\033[1;32m"
	blue   = "\033[1;34m"
	yellow = "\033[1;33m"
	reset  = "\033[0;0m"
)

var (
	searchExpr       = regexp.MustCompile(`(?s)<tr.*?>.*?<td class="filename">.*?<a class="download" href="(/dl/go(\d+\.\d+(?:\.\d+)?)\.(\w+)-(\w+)\.tar\.gz)">.*?<td><tt>(.*?)</tt></td>`)
	parseVersionExpr = regexp.MustCompile(`(\d+)\.(\d+)(?:\.(\d+))?`)
)

type semver struct {
	major int
	minor int
	patch int
}

type version struct {
	url      string
	semver   *semver
	os       string
	arch     string
	checksum string
}

func (v *version) str() string {
	if v.semver.patch >= 0 {
		return fmt.Sprintf("%d.%d.%d/%s/%s", v.semver.major, v.semver.minor, v.semver.patch, v.os, v.arch)
	}

	return fmt.Sprintf("%d.%d/%s/%s", v.semver.major, v.semver.minor, v.os, v.arch)
}

func newSemVer(s string) *semver {
	matches := parseVersionExpr.FindStringSubmatch(s)
	if matches == nil {
		return nil
	}

	major, _ := strconv.ParseInt(matches[1], 10, 64)
	minor, _ := strconv.ParseInt(matches[2], 10, 64)
	patch, _ := strconv.ParseInt(matches[3], 10, 64)
	if matches[3] == "" {
		patch = -1
	}

	return &semver{
		major: int(major),
		minor: int(minor),
		patch: int(patch),
	}
}

func compare(a *semver, b *semver) int {
	if a.major > b.major {
		return 1
	}
	if a.major < b.major {
		return -1
	}

	if a.minor > b.minor {
		return 1
	}
	if a.minor < b.minor {
		return -1
	}

	if a.patch > b.patch {
		return 1
	}
	if a.patch < b.patch {
		return -1
	}

	return 0
}

func pancake(err error) {
	if err != nil {
		panic(err)
	}
}

func msg(s string, c ...string) {
	color := reset
	if len(c) > 0 {
		color = c[0]
	}

	fmt.Println(color + s + reset)
}

func exists(path string) bool {
	if _, err := os.Stat(path); err == nil {
		return true
	}

	return false
}

func read(path string) string {
	b, err := ioutil.ReadFile(path)
	pancake(err)
	return string(b)
}

func write(path string, data string) {
	err := ioutil.WriteFile(path, []byte(data), 0644)
	pancake(err)
}

func rimraf(path string) {
	os.RemoveAll(path)
}

func mkdirp(path string) {
	os.MkdirAll(path, 0755)
}

func main() {
	root, err := os.Getwd()
	pancake(err)

	// fetch https://golang.org/dl/ ...

	body := ""
	if exists(root + "/tmp/dl.html") {
		msg("Using cache: #{root}/tmp/dl.html", yellow)
		body = read(root + "/tmp/dl.html")
	} else {
		msg("Fetching https://golang.org/dl/", green)

		response, err := http.Get("https://golang.org/dl/")
		pancake(err)
		defer response.Body.Close()

		b, err := ioutil.ReadAll(response.Body)
		pancake(err)
		body = string(b)
	}

	// parse versions from the html ...

	matches := searchExpr.FindAllStringSubmatch(body, -1)
	if matches == nil {
		panic("no matches found")
	}

	newVersions := []*version{}
	for _, match := range matches {
		switch match[4] {
		case "386":
			match[4] = "i686"
		case "amd64":
			match[4] = "x86_64"
		}

		ver := &version{
			url:      "https://golang.org" + match[1],
			semver:   newSemVer(match[2]),
			os:       match[3],
			arch:     match[4],
			checksum: match[5],
		}
		newVersions = append(newVersions, ver)
	}

	sort.Slice(newVersions, func(a int, b int) bool {
		return compare(newVersions[a].semver, newVersions[b].semver) == -1
	})

	// get known versions from fs ...

	glob, err := filepath.Glob(root + "/db/*/*/*/url")
	pancake(err)

	oldVersions := []*version{}
	for _, path := range glob {
		path = filepath.Dir(path)
		segments := strings.Split(path, "/")
		segments = segments[len(segments)-3:]

		ver := &version{
			url:      read(path + "/url"),
			semver:   newSemVer(segments[0]),
			os:       segments[1],
			arch:     segments[2],
			checksum: read(path + "/checksum"),
		}
		oldVersions = append(oldVersions, ver)
	}

	sort.Slice(oldVersions, func(a int, b int) bool {
		return compare(oldVersions[a].semver, oldVersions[b].semver) == -1
	})

	// remove everything ...

	msg("Removing old versions ...", red)
	rimraf(root + "/db")

	// create them anew ...

	for _, newVersion := range newVersions {
		same := false
		existing := false

		for idx, oldVersion := range oldVersions {
			same = oldVersion.url == newVersion.url &&
				compare(oldVersion.semver, newVersion.semver) == 0 &&
				oldVersion.os == newVersion.os &&
				oldVersion.arch == newVersion.arch &&
				oldVersion.checksum == newVersion.checksum
			existing = compare(oldVersion.semver, newVersion.semver) == 0 &&
				oldVersion.os == newVersion.os &&
				oldVersion.arch == newVersion.arch

			if same || existing {
				oldVersions = append(oldVersions[:idx], oldVersions[idx+1:]...)
				break
			}
		}

		if same {
			msg("Keep    " + newVersion.str())
		} else if existing {
			msg("Freshen "+newVersion.str(), yellow)
		} else {
			msg("Create  "+newVersion.str(), green)
		}

		mkdirp(root + "/db/" + newVersion.str())
		write(root+"/db/"+newVersion.str()+"/url", newVersion.url)
		write(root+"/db/"+newVersion.str()+"/checksum", newVersion.checksum)
	}

	// tell about yanked versions ...

	for _, oldVersion := range oldVersions {
		msg("Remove  "+oldVersion.str(), red)
	}
}
