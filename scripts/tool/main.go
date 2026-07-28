package main

import (
	"bufio"
	"bytes"
	"encoding/json"
	"flag"
	"fmt"
	"io"
	"log"
	"net/http"
	"os"
	"os/exec"
	"path/filepath"
	"sort"
	"strings"

	"github.com/Masterminds/semver/v3"
	"gopkg.in/yaml.v3"
	"helm.sh/helm/v3/pkg/chart/loader"
	"helm.sh/helm/v3/pkg/chartutil"
	"helm.sh/helm/v3/pkg/cli"
	"helm.sh/helm/v3/pkg/engine"
	"helm.sh/helm/v3/pkg/getter"
	"helm.sh/helm/v3/pkg/repo"
)

type BaseConfig struct {
	Apps map[string]AppDef `yaml:"apps"`
}

type AppDef struct {
	Type              string `yaml:"type"`
	URL               string `yaml:"url"`
	RepoName          string `yaml:"repo_name"`
	RepoURL           string `yaml:"repo_url"`
	Chart             string `yaml:"chart"`
	Namespace         string `yaml:"namespace"`
	CreateNamespace   bool   `yaml:"create_namespace"`
	KustomizeNamespace *bool `yaml:"kustomize_namespace"`
	GitHubRepo        string `yaml:"github_repo"`
}

type TypeConfig struct {
	InstallList []string          `yaml:"install_list"`
	Versions    map[string]string `yaml:"versions"`
}

type EnvConfig struct {
	Type string `yaml:"type"`
	Env  string `yaml:"env"`
}

var (
	baseDir      string
	manifestsDir string
	baseConfig   BaseConfig
	targetType   string
	targetApp    string
	forceFlag    bool
	checkFlag    bool
	diffFlag     bool
	allTypes     bool
	updateFlag   bool
	listFlag     bool
	keepVersions int
)

func main() {
	flag.StringVar(&targetType, "type", "", "Cluster type (talos, kind, etc.)")
	flag.BoolVar(&allTypes, "all-types", false, "Generate for all types")
	flag.StringVar(&targetApp, "app", "", "Specific app")
	flag.BoolVar(&forceFlag, "f", false, "Force regeneration")
	flag.BoolVar(&checkFlag, "check", false, "Version check only")
	flag.BoolVar(&diffFlag, "diff", false, "Diff last two versions of an app")
	flag.BoolVar(&updateFlag, "u", false, "Update versions to latest upstream")
	flag.BoolVar(&listFlag, "l", false, "List apps")
	flag.IntVar(&keepVersions, "keep", 2, "Number of versions to keep per app per type")
	flag.Parse()

	repoRoot, err := exec.Command("git", "rev-parse", "--show-toplevel").Output()
	if err != nil {
		log.Fatal("must be in a git repo")
	}
	baseDir = strings.TrimSpace(string(repoRoot))
	manifestsDir = filepath.Join(baseDir, "manifests")

	loadYAML(filepath.Join(baseDir, "clusters", "default_app_config.yaml"), &baseConfig)
	loadClusterScoped(filepath.Join(baseDir, "clusters", "cluster-scoped.yaml"))

	if listFlag {
		keys := make([]string, 0, len(baseConfig.Apps))
		for k := range baseConfig.Apps {
			keys = append(keys, k)
		}
		sort.Strings(keys)
		for _, name := range keys {
			fmt.Println(name)
		}
		return
	}

	if diffFlag {
		handleDiff()
		return
	}

	if checkFlag {
		handleCheck()
		return
	}

	var types []string
	if allTypes {
		entries, _ := os.ReadDir(filepath.Join(baseDir, "clusters", "types"))
		for _, e := range entries {
			if e.IsDir() {
				types = append(types, e.Name())
			}
		}
	} else if targetType != "" {
		types = append(types, targetType)
	} else {
		log.Fatal("--type or --all-types required")
	}

	for _, t := range types {
		processType(t)
	}
}

func handleDiff() {
	if targetApp == "" {
		log.Fatal("--diff requires --app")
	}
	types := []string{targetType}
	if allTypes {
		entries, _ := os.ReadDir(filepath.Join(baseDir, "clusters", "types"))
		for _, e := range entries {
			if e.IsDir() {
				types = append(types, e.Name())
			}
		}
	}
	for _, t := range types {
		diffTypeApp(t, targetApp)
	}
}

func diffTypeApp(typeName, appName string) {
	var compDir string
	app, ok := baseConfig.Apps[appName]
	if !ok {
		log.Printf("[SKIP] %s not in default_app_config.yaml", appName)
		return
	}
	if app.Type == "url" {
		compDir = filepath.Join(manifestsDir, appName, "components")
	} else {
		compDir = filepath.Join(manifestsDir, appName, "components", typeName)
	}
	entries, err := os.ReadDir(compDir)
	if err != nil || len(entries) < 2 {
		log.Printf("[SKIP] %s/%s: need at least 2 versions in %s", typeName, appName, compDir)
		return
	}
	vers := make([]string, 0, len(entries))
	for _, e := range entries {
		if e.IsDir() {
			vers = append(vers, e.Name())
		}
	}
	sort.Strings(vers)
	if len(vers) < 2 {
		return
	}
	v1 := vers[len(vers)-2]
	v2 := vers[len(vers)-1]
	fmt.Printf("[DIFF] %s/%s: %s vs %s\n", typeName, appName, v1, v2)
	dir1 := filepath.Join(compDir, v1)
	dir2 := filepath.Join(compDir, v2)
	cmd := exec.Command("diff", "-uNr", dir1, dir2)
	cmd.Stdout = os.Stdout
	cmd.Stderr = os.Stderr
	cmd.Run()
}

func handleCheck() {
	if targetType == "" && !allTypes {
		log.Fatal("--check requires --type or --all-types")
	}
	types := []string{targetType}
	if allTypes {
		entries, _ := os.ReadDir(filepath.Join(baseDir, "clusters", "types"))
		for _, e := range entries {
			if e.IsDir() {
				types = append(types, e.Name())
			}
		}
	}
	for _, t := range types {
		checkType(t)
	}
}

func checkType(typeName string) {
	var cfg TypeConfig
	path := filepath.Join(baseDir, "clusters", "types", typeName, "app_config.yaml")
	if _, err := os.Stat(path); os.IsNotExist(err) {
		return
	}
	loadYAML(path, &cfg)

	apps := cfg.InstallList
	if targetApp != "" {
		found := false
		for _, a := range apps {
			if a == targetApp {
				found = true
				apps = []string{targetApp}
				break
			}
		}
		if !found {
			return
		}
	}

	for _, appName := range apps {
		app, ok := baseConfig.Apps[appName]
		if !ok {
			continue
		}
		current := cfg.Versions[appName]
		latest := fetchLatestVersion(app)
		if latest == "" {
			log.Printf("[CHECK] %s/%s: current=%s latest=unknown", typeName, appName, current)
		} else if current == latest || stripVPrefix(current) == stripVPrefix(latest) {
			log.Printf("[CHECK] %s/%s: %s (up to date)", typeName, appName, current)
		} else {
			log.Printf("[CHECK] %s/%s: %s -> %s (update available)", typeName, appName, current, latest)
		}
	}
}

func processType(typeName string) {
	var cfg TypeConfig
	path := filepath.Join(baseDir, "clusters", "types", typeName, "app_config.yaml")
	if _, err := os.Stat(path); os.IsNotExist(err) {
		log.Printf("[SKIP] no config for type %s", typeName)
		return
	}
	loadYAML(path, &cfg)

	apps := cfg.InstallList
	if targetApp != "" {
		found := false
		for _, a := range apps {
			if a == targetApp {
				found = true
				apps = []string{targetApp}
				break
			}
		}
		if !found {
			log.Printf("[SKIP] %s not in %s install list", targetApp, typeName)
			return
		}
	}

	envs := matchingEnvs(typeName)

	for _, appName := range apps {
		app, ok := baseConfig.Apps[appName]
		if !ok {
			log.Printf("[SKIP] %s not in default_app_config.yaml", appName)
			continue
		}

		version := cfg.Versions[appName]
		if version == "" {
			log.Printf("[SKIP] %s has no version for %s", appName, typeName)
			continue
		}

		if updateFlag {
			latest := fetchLatestVersion(app)
			if latest != "" {
				norm := stripVPrefix(version)
				latNorm := stripVPrefix(latest)
				if latNorm != norm {
					log.Printf("[UPDATE] %s: %s -> %s", appName, version, latest)
					cfg.Versions[appName] = latest
					version = latest
					saveYAML(path, cfg)
				}
			}
		}

		log.Printf("[INFO] %s (%s) for %s", appName, version, typeName)
		generateApp(appName, version, typeName, app, envs)
	}
}

func generateApp(appName, version, typeName string, app AppDef, envs []string) {
	var outDir string
	if app.Type == "url" {
		outDir = filepath.Join(manifestsDir, appName, "components", version)
	} else {
		outDir = filepath.Join(manifestsDir, appName, "components", typeName, version)
	}

	if !forceFlag {
		if _, err := os.Stat(outDir); err == nil {
			log.Printf("[SKIP] %s/%s: already exists (use -f to force)", typeName, appName)
			return
		}
	}

	os.RemoveAll(outDir)
	os.MkdirAll(outDir, 0755)

	if app.Namespace != "" && app.CreateNamespace {
		nsFile := filepath.Join(outDir, "01-namespace.yaml")
		content := fmt.Sprintf("apiVersion: v1\nkind: Namespace\nmetadata:\n  name: %s\n  labels:\n    shared-gateway-access: \"true\"\n", app.Namespace)
		os.WriteFile(nsFile, []byte(content), 0644)
	}

	var rawYAML string
	var err error

	if app.Type == "url" {
		rawYAML, err = fetchURL(app.URL, version)
		if err != nil {
			log.Printf("[ERR] fetch %s: %v", appName, err)
			return
		}
	} else if app.Type == "helm" {
		rawYAML, err = renderHelm(appName, version, typeName, app)
		if err != nil {
			log.Printf("[ERR] helm %s: %v", appName, err)
			return
		}
	}

	processAndSlice(rawYAML, outDir)
	kustomizeNamespace := true
	if app.KustomizeNamespace != nil {
		kustomizeNamespace = *app.KustomizeNamespace
	}
	generateKustomization(outDir, app.Namespace, app.Namespace != "" && kustomizeNamespace)
	if app.Namespace != "" && !kustomizeNamespace {
		ensureNamespaces(outDir, app.Namespace)
	}
	updateOverlays(appName, version, typeName, app, envs)
	cleanupOldVersions(appName, version, typeName, app)
	lintDir(outDir)
}

func cleanupOldVersions(appName, currentVersion, typeName string, app AppDef) {
	var compDir string
	if app.Type == "url" {
		compDir = filepath.Join(manifestsDir, appName, "components")
	} else {
		compDir = filepath.Join(manifestsDir, appName, "components", typeName)
	}

	entries, err := os.ReadDir(compDir)
	if err != nil {
		return
	}

	vers := make([]string, 0, len(entries))
	for _, e := range entries {
		if e.IsDir() && e.Name() != currentVersion {
			vers = append(vers, e.Name())
		}
	}

	if len(vers) < keepVersions {
		return
	}

	sort.Slice(vers, func(i, j int) bool {
		return compareVersions(vers[i], vers[j]) < 0
	})

	remove := vers[:len(vers)-(keepVersions-1)]
	for _, v := range remove {
		dir := filepath.Join(compDir, v)
		log.Printf("[CLEAN] %s/%s: removing %s", typeName, appName, v)
		os.RemoveAll(dir)
	}
}

func compareVersions(a, b string) int {
	av := strings.TrimLeft(a, "v")
	bv := strings.TrimLeft(b, "v")
	if av == bv {
		return strings.Compare(a, b)
	}
	status, _ := exec.Command("sort", "-V", "-C").CombinedOutput()
	_ = status
	cmd := exec.Command("sort", "-V")
	stdin, _ := cmd.StdinPipe()
	stdin.Write([]byte(av + "\n" + bv + "\n"))
	stdin.Close()
	out, _ := cmd.Output()
	lines := strings.Split(strings.TrimSpace(string(out)), "\n")
	if len(lines) == 2 {
		if lines[0] == av && lines[1] == bv {
			return -1
		}
		return 1
	}
	return strings.Compare(av, bv)
}

func fetchURL(urlTemplate, version string) (string, error) {
	url := strings.ReplaceAll(urlTemplate, "${VERSION}", version)
	resp, err := http.Get(url)
	if err != nil {
		return "", err
	}
	defer resp.Body.Close()

	body, err := io.ReadAll(resp.Body)
	if err != nil {
		return "", err
	}
	return string(body), nil
}

func renderHelm(appName, version, typeName string, app AppDef) (string, error) {
	pullVer := stripVPrefix(version)
	settings := cli.New()

	tmpDir, err := os.MkdirTemp("", "helm-*")
	if err != nil {
		return "", err
	}
	defer os.RemoveAll(tmpDir)

	settings.RepositoryCache = filepath.Join(tmpDir, "cache")
	os.MkdirAll(settings.RepositoryCache, 0755)

	providers := getter.All(settings)

	repoEntry := &repo.Entry{
		Name: app.RepoName,
		URL:  app.RepoURL,
	}

	chartRepo, err := repo.NewChartRepository(repoEntry, providers)
	if err != nil {
		return "", fmt.Errorf("new chart repo: %w", err)
	}

	idxFile, err := chartRepo.DownloadIndexFile()
	if err != nil {
		return "", fmt.Errorf("download index: %w", err)
	}
	defer os.Remove(idxFile)

	idx, err := repo.LoadIndexFile(idxFile)
	if err != nil {
		return "", fmt.Errorf("load index: %w", err)
	}

	cv, err := idx.Get(app.Chart, pullVer)
	if err != nil {
		return "", fmt.Errorf("chart version %s: %w", pullVer, err)
	}

	if len(cv.URLs) == 0 {
		return "", fmt.Errorf("no URLs for chart %s %s", app.Chart, pullVer)
	}

	chartURL := cv.URLs[0]
	if !strings.Contains(chartURL, "://") {
		baseURL := strings.TrimRight(app.RepoURL, "/")
		chartURL = baseURL + "/" + strings.TrimLeft(chartURL, "/")
	}

	g, err := providers.ByScheme(strings.SplitN(chartURL, "://", 2)[0])
	if err != nil {
		return "", fmt.Errorf("no getter for %s: %w", chartURL, err)
	}

	buf, err := g.Get(chartURL)
	if err != nil {
		return "", fmt.Errorf("download chart: %w", err)
	}

	chartTmp := filepath.Join(tmpDir, "chart.tgz")
	if err := os.WriteFile(chartTmp, buf.Bytes(), 0644); err != nil {
		return "", err
	}

	chart, err := loader.Load(chartTmp)
	if err != nil {
		return "", fmt.Errorf("load chart: %w", err)
	}

	vals := chartutil.Values{}
	vals = mergeMaps(vals, chart.Values)

	defaultValsFile := filepath.Join(manifestsDir, appName, "values", "default.yaml")
	if _, err := os.Stat(defaultValsFile); err == nil {
		fv, err := chartutil.ReadValuesFile(defaultValsFile)
		if err == nil {
			vals = mergeMaps(vals, fv)
		}
	}

	typeValsFile := filepath.Join(manifestsDir, appName, "values", typeName+".yaml")
	if _, err := os.Stat(typeValsFile); err == nil {
		fv, err := chartutil.ReadValuesFile(typeValsFile)
		if err == nil {
			vals = mergeMaps(vals, fv)
		}
	}

	options := chartutil.ReleaseOptions{
		Name:      appName,
		Namespace: app.Namespace,
		Revision:  1,
		IsInstall: true,
	}

	caps := chartutil.DefaultCapabilities

	renderVals, err := chartutil.ToRenderValues(chart, vals, options, caps)
	if err != nil {
		return "", fmt.Errorf("render values: %w", err)
	}

	rendered, err := engine.Render(chart, renderVals)
	if err != nil {
		return "", fmt.Errorf("engine render: %w", err)
	}

	var out bytes.Buffer
	keys := make([]string, 0, len(rendered))
	for k := range rendered {
		keys = append(keys, k)
	}
	sort.Strings(keys)
	for _, k := range keys {
		trimmed := strings.TrimSpace(rendered[k])
		if trimmed == "" {
			continue
		}
		if isSubchartDisabled(k, vals) {
			continue
		}
		out.WriteString("---\n")
		out.WriteString(trimmed + "\n")
	}

	for _, crd := range chart.CRDObjects() {
		out.WriteString("---\n")
		out.WriteString(trimTrailingWhitespace(string(crd.File.Data)))
		out.WriteString("\n")
	}

	return out.String(), nil
}

func mergeMaps(a, b map[string]interface{}) map[string]interface{} {
	if a == nil {
		a = make(map[string]interface{})
	}
	for k, v := range b {
		if bm, ok := v.(map[string]interface{}); ok {
			if am, ok := a[k].(map[string]interface{}); ok {
				a[k] = mergeMaps(am, bm)
			} else {
				a[k] = v
			}
		} else if bArr, ok := v.([]interface{}); ok {
			a[k] = bArr
		} else {
			a[k] = v
		}
	}
	return a
}

func isSubchartDisabled(key string, vals map[string]interface{}) bool {
	before, _, _ := strings.Cut(key, "/templates/")
	if before == "" {
		return false
	}
	subchartName := before
	if _, after, found := strings.Cut(before, "/charts/"); found {
		subchartName = after
	}
	sub, ok := vals[subchartName]
	if !ok {
		return false
	}
	sm, ok := sub.(map[string]interface{})
	if !ok {
		return false
	}
	enabled, ok := sm["enabled"]
	if !ok {
		return false
	}
	b, ok := enabled.(bool)
	return ok && !b
}

func cleanDocBlanks(lines []string) []string {
	if len(lines) == 0 {
		return lines
	}
	var out []string
	inBlock := false
	blockIndent := 0
	for _, line := range lines {
		if inBlock {
			if strings.TrimSpace(line) != "" {
				indent := len(line) - len(strings.TrimLeft(line, " \t"))
				if indent <= blockIndent {
					inBlock = false
				} else {
					out = append(out, line)
					continue
				}
			} else {
				out = append(out, line)
				continue
			}
		}
		if strings.TrimSpace(line) == "" {
			continue
		}
		if isBlockScalarHeader(line) {
			inBlock = true
			blockIndent = len(line) - len(strings.TrimLeft(line, " \t"))
		}
		out = append(out, line)
	}
	return out
}

func isBlockScalarHeader(line string) bool {
	trimmed := strings.TrimSpace(line)
	return strings.HasSuffix(trimmed, ": |") ||
		strings.HasSuffix(trimmed, ": >") ||
		strings.HasSuffix(trimmed, ": |-") ||
		strings.HasSuffix(trimmed, ": >-") ||
		strings.HasSuffix(trimmed, ": |+") ||
		strings.HasSuffix(trimmed, ": >+")
}

var clusterScopedKinds map[string]bool

func loadClusterScoped(path string) {
	var kinds []string
	data, err := os.ReadFile(path)
	if err != nil {
		log.Printf("[WARN] cluster-scoped kinds not found at %s: %v", path, err)
		return
	}
	if err := yaml.Unmarshal(data, &kinds); err != nil {
		log.Printf("[WARN] parsing %s: %v", path, err)
		return
	}
	m := make(map[string]bool, len(kinds))
	for _, k := range kinds {
		m[k] = true
	}
	clusterScopedKinds = m
}

var strippedKinds = map[string]bool{
	"ClusterRole": true, "ClusterRoleBinding": true,
	"CustomResourceDefinition": true, "GatewayClass": true,
}

func ensureNamespaces(dir, ns string) {
	entries, _ := os.ReadDir(dir)
	for _, e := range entries {
		if e.IsDir() || !strings.HasSuffix(e.Name(), ".yaml") || e.Name() == "kustomization.yaml" || e.Name() == "01-namespace.yaml" {
			continue
		}
		data, err := os.ReadFile(filepath.Join(dir, e.Name()))
		if err != nil {
			continue
		}
		result := addNamespacesToFile(data, ns)
		if string(result) != string(data) {
			os.WriteFile(filepath.Join(dir, e.Name()), result, 0644)
		}
	}
}

func addNamespacesToFile(data []byte, ns string) []byte {
	var out bytes.Buffer
	scanner := bufio.NewScanner(bytes.NewReader(data))
	var docLines []string
	flushDoc := func() {
		if len(docLines) == 0 {
			return
		}
		out.WriteString(ensureDocNamespace(strings.Join(docLines, "\n"), ns))
		out.WriteString("\n")
		docLines = nil
	}
	for scanner.Scan() {
		line := scanner.Text()
		if strings.TrimSpace(line) == "---" {
			flushDoc()
			out.WriteString("---\n")
			continue
		}
		docLines = append(docLines, line)
	}
	flushDoc()
	return out.Bytes()
}

func ensureDocNamespace(doc, ns string) string {
	lines := strings.Split(doc, "\n")
	kind := ""
	inMetadata := false
	hasNS := false
	for _, line := range lines {
		trimmed := strings.TrimSpace(line)
		if strings.HasPrefix(trimmed, "kind:") && kind == "" {
			kind = strings.TrimSpace(strings.TrimPrefix(trimmed, "kind:"))
		}
		if trimmed == "metadata:" {
			inMetadata = true
			continue
		}
		if inMetadata {
			if strings.HasPrefix(trimmed, "namespace:") {
				hasNS = true
				break
			}
			if trimmed != "" && !strings.HasPrefix(line, " ") && !strings.HasPrefix(line, "\t") {
				inMetadata = false
			}
		}
	}
	if hasNS || clusterScopedKinds[kind] {
		return doc
	}
	var out []string
	for _, line := range lines {
		out = append(out, line)
		if strings.TrimSpace(line) == "metadata:" {
			out = append(out, "  namespace: "+ns)
		}
	}
	return strings.Join(out, "\n")
}

func stripNamespace(content, kind string) string {
	if !strippedKinds[kind] {
		return content
	}
	var out []string
	inMeta := false
	doneMeta := false
	for _, line := range strings.Split(content, "\n") {
		trimmed := strings.TrimSpace(line)
		if trimmed == "metadata:" {
			if !doneMeta {
				inMeta = true
				out = append(out, line)
			} else {
				out = append(out, line)
			}
			continue
		}
		if inMeta {
			if line == "" || strings.HasPrefix(line, " ") || strings.HasPrefix(line, "\t") {
				if strings.HasPrefix(trimmed, "namespace:") {
					continue
				}
				out = append(out, line)
			} else {
				inMeta = false
				doneMeta = true
				out = append(out, line)
			}
		} else {
			out = append(out, line)
		}
	}
	return strings.Join(out, "\n")
}

func processAndSlice(raw string, outDir string) {
	scanner := bufio.NewScanner(strings.NewReader(raw))
	buf := make([]byte, 0, 64*1024)
	scanner.Buffer(buf, 1024*1024)

	var currentDoc []string
	var kind string

	flushDoc := func() {
		cleaned := cleanDocBlanks(currentDoc)
		content := strings.TrimSpace(strings.Join(cleaned, "\n"))
		if content == "" || kind == "" || strings.ToLower(kind) == "namespace" {
			currentDoc, kind = nil, ""
			return
		}
		content = stripNamespace(content, kind)
		fpath := filepath.Join(outDir, strings.ToLower(kind)+".yaml")
		f, _ := os.OpenFile(fpath, os.O_APPEND|os.O_CREATE|os.O_WRONLY, 0644)
		f.WriteString("---\n" + content + "\n")
		f.Close()
		currentDoc, kind = nil, ""
	}

	for scanner.Scan() {
		line := scanner.Text()
		if strings.HasPrefix(line, "---") {
			flushDoc()
			continue
		}
		trimmed := strings.TrimSpace(line)
		if strings.HasPrefix(trimmed, "# Source:") ||
			strings.HasPrefix(trimmed, "# imagePullSecrets") ||
			strings.HasPrefix(trimmed, "#   ") ||
			strings.Contains(trimmed, "helm.sh/chart:") ||
			strings.Contains(trimmed, "app.kubernetes.io/managed-by:") ||
			strings.Contains(trimmed, "heritage: Tiller") ||
			strings.Contains(trimmed, "created-by: helm") {
			continue
		}
		if strings.HasPrefix(line, "kind:") {
			k := strings.TrimSpace(strings.TrimPrefix(line, "kind:"))
			if kind == "" {
				kind = strings.Trim(k, `"'`)
			}
		}
		currentDoc = append(currentDoc, strings.TrimRight(line, " \t"))
	}
	flushDoc()
}

func generateKustomization(dir, namespace string, setNS bool) {
	var files []string
	entries, _ := os.ReadDir(dir)
	for _, e := range entries {
		if !e.IsDir() && strings.HasSuffix(e.Name(), ".yaml") && e.Name() != "kustomization.yaml" {
			files = append(files, e.Name())
		}
	}
	if len(files) == 0 {
		return
	}
	sort.Strings(files)

	var buf bytes.Buffer
	buf.WriteString("apiVersion: kustomize.config.k8s.io/v1beta1\nkind: Kustomization\nresources:\n")
	for _, f := range files {
		buf.WriteString(fmt.Sprintf("  - %s\n", f))
	}
	if setNS && namespace != "" {
		buf.WriteString(fmt.Sprintf("namespace: %s\n", namespace))
	}
	os.WriteFile(filepath.Join(dir, "kustomization.yaml"), buf.Bytes(), 0644)
}

func updateOverlays(appName, version, typeName string, app AppDef, envs []string) {
	appDir := filepath.Join(manifestsDir, appName)

	for _, env := range envs {
		ovlDir := filepath.Join(appDir, "overlays", env)
		os.MkdirAll(ovlDir, 0755)

		var compPath string
		if app.Type == "url" {
			compPath = fmt.Sprintf("../../components/%s", version)
		} else {
			compPath = fmt.Sprintf("../../components/%s/%s", typeName, version)
		}

		var buf bytes.Buffer
		buf.WriteString("apiVersion: kustomize.config.k8s.io/v1beta1\nkind: Kustomization\nresources:\n")
		buf.WriteString(fmt.Sprintf("  - %s\n", compPath))

		resPath := filepath.Join(appDir, "resources")
		if hasYAMLFiles(resPath) {
			genBaseKustomization(resPath)
			buf.WriteString("  - ../../resources\n")
		}

		ovlResPath := filepath.Join(ovlDir, "resources")
		if hasYAMLFiles(ovlResPath) {
			genBaseKustomization(ovlResPath)
			buf.WriteString("  - resources\n")
		}

		patchesDir := filepath.Join(ovlDir, "patches")
		if hasYAMLFiles(patchesDir) {
			buf.WriteString("patches:\n")
			entries, _ := os.ReadDir(patchesDir)
			for _, e := range entries {
				if !e.IsDir() && strings.HasSuffix(e.Name(), ".yaml") {
					buf.WriteString(fmt.Sprintf("  - path: patches/%s\n", e.Name()))
				}
			}
		}

		os.WriteFile(filepath.Join(ovlDir, "kustomization.yaml"), buf.Bytes(), 0644)
		log.Printf("[OVL] %s/overlays/%s", appName, env)
	}
}

func hasYAMLFiles(dir string) bool {
	entries, err := os.ReadDir(dir)
	if err != nil {
		return false
	}
	for _, e := range entries {
		if !e.IsDir() && strings.HasSuffix(e.Name(), ".yaml") && e.Name() != "kustomization.yaml" {
			return true
		}
	}
	return false
}

func genBaseKustomization(dir string) {
	kPath := filepath.Join(dir, "kustomization.yaml")
	if _, err := os.Stat(kPath); os.IsNotExist(err) {
		var files []string
		entries, _ := os.ReadDir(dir)
		for _, e := range entries {
			if !e.IsDir() && strings.HasSuffix(e.Name(), ".yaml") && e.Name() != "kustomization.yaml" {
				files = append(files, e.Name())
			}
		}
		if len(files) == 0 {
			return
		}
		sort.Strings(files)
		var buf bytes.Buffer
		buf.WriteString("apiVersion: kustomize.config.k8s.io/v1beta1\nkind: Kustomization\nresources:\n")
		for _, f := range files {
			buf.WriteString(fmt.Sprintf("  - %s\n", f))
		}
		os.WriteFile(kPath, buf.Bytes(), 0644)
	}
}

func matchingEnvs(typeName string) []string {
	var envs []string
	entries, _ := os.ReadDir(filepath.Join(baseDir, "clusters", "envs"))
	for _, e := range entries {
		if !e.IsDir() {
			continue
		}
		var ec EnvConfig
		cfgPath := filepath.Join(baseDir, "clusters", "envs", e.Name(), "config.yaml")
		if _, err := os.Stat(cfgPath); os.IsNotExist(err) {
			continue
		}
		loadYAML(cfgPath, &ec)
		if ec.Type == typeName {
			envs = append(envs, e.Name())
		}
	}
	return envs
}

func fetchLatestVersion(app AppDef) string {
	if app.GitHubRepo != "" {
		resp, err := http.Get(fmt.Sprintf("https://api.github.com/repos/%s/releases/latest", app.GitHubRepo))
		if err == nil {
			defer resp.Body.Close()
			var result struct{ TagName string `json:"tag_name"` }
			json.NewDecoder(resp.Body).Decode(&result)
			return result.TagName
		}
	}
	if app.Type == "helm" {
		settings := cli.New()
		providers := getter.All(settings)

		tmpDir, _ := os.MkdirTemp("", "helm-*")
		defer os.RemoveAll(tmpDir)
		settings.RepositoryCache = filepath.Join(tmpDir, "cache")
		os.MkdirAll(settings.RepositoryCache, 0755)

		repoEntry := &repo.Entry{
			Name: app.RepoName,
			URL:  app.RepoURL,
		}
		chartRepo, err := repo.NewChartRepository(repoEntry, providers)
		if err != nil {
			return ""
		}
		idxFile, err := chartRepo.DownloadIndexFile()
		if err != nil {
			return ""
		}
		defer os.Remove(idxFile)

		idx, _ := repo.LoadIndexFile(idxFile)
		if idx == nil {
			return ""
		}
		var latest *semver.Version
		for _, entry := range idx.Entries[app.Chart] {
			v, err := semver.StrictNewVersion(entry.Version)
			if err != nil || v.Prerelease() != "" {
				continue
			}
			if latest == nil || v.GreaterThan(latest) {
				latest = v
			}
		}
		if latest != nil {
			return latest.Original()
		}
		return ""
	}
	return ""
}

func stripVPrefix(v string) string {
	return strings.TrimLeft(v, "v")
}

func trimTrailingWhitespace(s string) string {
	var out bytes.Buffer
	scanner := bufio.NewScanner(strings.NewReader(s))
	for scanner.Scan() {
		out.WriteString(strings.TrimRight(scanner.Text(), " \t"))
		out.WriteString("\n")
	}
	return out.String()
}

func lintDir(dir string) {
	cmd := exec.Command("pre-commit", "run", "--config", filepath.Join(baseDir, ".pre-commit-config.yaml"), "--files")
	entries, _ := os.ReadDir(dir)
	for _, e := range entries {
		if !e.IsDir() && strings.HasSuffix(e.Name(), ".yaml") {
			cmd.Args = append(cmd.Args, filepath.Join(dir, e.Name()))
		}
	}
	if len(cmd.Args) <= 4 {
		return
	}
	cmd.Stderr = os.Stderr
	cmd.Run()
}

func loadYAML(path string, target interface{}) {
	data, err := os.ReadFile(path)
	if err == nil {
		yaml.Unmarshal(data, target)
	}
}

func saveYAML(path string, data interface{}) {
	out, _ := yaml.Marshal(data)
	os.WriteFile(path, out, 0644)
}
