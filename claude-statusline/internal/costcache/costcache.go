// Package costcache reads the cost tally the background refresh leaves behind.
package costcache

import (
	"os"
	"path/filepath"
	"strconv"
	"strings"
	"time"
)

// Cost is the tally of the cost row. Weekly and Monthly stay as the strings the file
// holds because the shell appended them after "$" without arithmetic, so reformatting
// them as numbers would change the printed amount.
type Cost struct {
	Available   bool
	DailyOpus   float64
	DailySonnet float64
	DailyHaiku  float64
	Weekly      string
	Monthly     string

	rawOpus   string
	rawSonnet string
	rawHaiku  string
}

// Segment is one per-model amount of the daily tally, already rounded.
type Segment struct {
	Label  string
	Amount string
}

// Load reads <cacheDir>/cost-cache.env. A missing or unfinished file reports
// Available false, which renders the row with placeholder amounts.
func Load(cacheDir string) Cost {
	var c Cost
	b, err := os.ReadFile(filepath.Join(cacheDir, "cost-cache.env"))
	if err != nil {
		return c
	}
	for _, line := range strings.Split(string(b), "\n") {
		k, v, found := strings.Cut(line, "=")
		if !found {
			continue
		}
		switch k {
		case "available":
			c.Available = v == "true"
		case "dailyOpus":
			c.rawOpus = v
		case "dailySonnet":
			c.rawSonnet = v
		case "dailyHaiku":
			c.rawHaiku = v
		case "weekly":
			c.Weekly = v
		case "monthly":
			c.Monthly = v
		}
	}
	c.DailyOpus, _ = strconv.ParseFloat(c.rawOpus, 64)
	c.DailySonnet, _ = strconv.ParseFloat(c.rawSonnet, 64)
	c.DailyHaiku, _ = strconv.ParseFloat(c.rawHaiku, 64)
	return c
}

// DailySegments lists the models that spent at least a dollar today, in the fixed
// Opus, Sonnet, Haiku order. A model below a dollar is left out entirely rather than
// shown as $0.
func (c Cost) DailySegments() []Segment {
	var out []Segment
	for _, m := range []struct {
		label, raw string
		value      float64
	}{
		{"Opus", c.rawOpus, c.DailyOpus},
		{"Sonnet", c.rawSonnet, c.DailySonnet},
		{"Haiku", c.rawHaiku, c.DailyHaiku},
	} {
		if !atLeastOne(m.raw) {
			continue
		}
		out = append(out, Segment{Label: m.label, Amount: strconv.FormatFloat(m.value, 'f', 0, 64)})
	}
	return out
}

// atLeastOne takes the text before the decimal point, requires it to be digits only,
// and compares it with one. A negative or unparseable amount therefore drops out
// instead of rendering as $0 or as a minus sign.
func atLeastOne(raw string) bool {
	intPart, _, _ := strings.Cut(raw, ".")
	if intPart == "" {
		return false
	}
	for i := 0; i < len(intPart); i++ {
		if intPart[i] < '0' || intPart[i] > '9' {
			return false
		}
	}
	n, err := strconv.Atoi(intPart)
	return err == nil && n >= 1
}

// MonthDays is the number of days in the month of day, which labels the monthly
// amount. Day zero of the next month is the last day of this one.
func MonthDays(day time.Time) string {
	y, m, _ := day.Date()
	return strconv.Itoa(time.Date(y, m+1, 0, 0, 0, 0, 0, day.Location()).Day())
}
