package main

import (
	"bufio"
	"bytes"
	"crypto"
	"crypto/ecdsa"
	"crypto/elliptic"
	"crypto/rsa"
	"crypto/sha256"
	"crypto/x509"
	"encoding/base64"
	"encoding/json"
	"encoding/pem"
	"flag"
	"fmt"
	"io"
	"log"
	"math/big"
	"net/http"
	"os"
	"os/exec"
	"path/filepath"
	"sort"
	"strings"

	"github.com/Masterminds/semver/v3"
	"gopkg.in/yaml.v3"
	"helm.sh/helm/v3/pkg/action"
	"helm.sh/helm/v3/pkg/chart"
	"helm.sh/helm/v3/pkg/chart/loader"
	"helm.sh/helm/v3/pkg/chartutil"
	"helm.sh/helm/v3/pkg/cli"
	"helm.sh/helm/v3/pkg/engine"
	"helm.sh/helm/v3/pkg/getter"
	"helm.sh/helm/v3/pkg/registry"
	"helm.sh/helm/v3/pkg/repo"
)

type BaseConfig struct {
	Apps map[string]AppDef `yaml:"apps"`
}

type AppDef struct {
	Type               string `yaml:"type"`
	URL                string `yaml:"url"`
	RepoName           string `yaml:"repo_name"`
	RepoURL            string `yaml:"repo_url"`
	Chart              string `yaml:"chart"`
	Namespace          string `yaml:"namespace"`
	CreateNamespace    bool   `yaml:"create_namespace"`
	KustomizeNamespace *bool  `yaml:"kustomize_namespace"`
	GitHubRepo         string `yaml:"github_repo"`
}

type TypeConfig struct {
	InstallList []string          `yaml:"install_list,omitempty"`
	Versions    map[string]string `yaml:"versions,omitempty"`
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
	envFlag      string
	ingestApp    string
	syncFlag     bool
	listFlag     bool
	oidcJWKFlag  bool
	keepVersions int
)

func main() {
	flag.StringVar(&targetType, "type", "", "Cluster type (talos, kind, etc.)")
	flag.BoolVar(&allTypes, "all-types", false, "Generate for all types")
	flag.StringVar(&envFlag, "env", "", "Environment (implies its type, e.g. homelab)")
	flag.StringVar(&targetApp, "app", "", "Specific app")
	flag.StringVar(&ingestApp, "ingest", "", "Ingest YAML from stdin/files into an app's resources dir (add --env for overlay resources)")
	flag.BoolVar(&syncFlag, "sync", false, "Regenerate all kustomization files without rendering (optional --app)")
	flag.BoolVar(&forceFlag, "f", false, "Force regeneration")
	flag.BoolVar(&checkFlag, "check", false, "Version check only")
	flag.BoolVar(&diffFlag, "diff", false, "Diff last two versions of an app")
	flag.BoolVar(&updateFlag, "u", false, "Update versions to latest upstream")
	flag.BoolVar(&listFlag, "l", false, "List apps")
	flag.IntVar(&keepVersions, "keep", 2, "Number of versions to keep per app per type")
	flag.BoolVar(&oidcJWKFlag, "oidc-jwk", false, "Generate OIDC JWKS from Talos secrets.yaml")
	flag.Parse()

	repoRoot, err := exec.Command("git", "rev-parse", "--show-toplevel").Output()
	if err != nil {
		log.Fatal("must be in a git repo")
	}
	baseDir = strings.TrimSpace(string(repoRoot))
	manifestsDir = filepath.Join(baseDir, "manifests")

	if oidcJWKFlag {
		handleOIDCJWK()
		return
	}

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

	if syncFlag {
		if targetType != "" || allTypes || envFlag != "" {
			log.Fatal("--sync takes no --type/--env (optional --app filter)")
		}
		handleSync()
		return
	}

	if ingestApp != "" {
		if targetApp != "" || targetType != "" || allTypes {
			log.Fatal("--ingest takes the app name; do not combine with --app/--type/--all-types")
		}
		handleIngest()
		return
	}

	var types []string
	switch {
	case envFlag != "":
		if targetType != "" {
			log.Fatal("--type and --env are mutually exclusive")
		}
		var ec EnvConfig
		envCfgPath := filepath.Join(baseDir, "clusters", "envs", envFlag, "config.yaml")
		if _, err := os.Stat(envCfgPath); os.IsNotExist(err) {
			log.Fatalf("no config for env %s (expected %s)", envFlag, envCfgPath)
		}
		loadYAML(envCfgPath, &ec)
		if ec.Type == "" {
			log.Fatalf("env %s has no type in %s", envFlag, envCfgPath)
		}
		types = append(types, ec.Type)
	case allTypes:
		entries, _ := os.ReadDir(filepath.Join(baseDir, "clusters", "types"))
		for _, e := range entries {
			if e.IsDir() {
				types = append(types, e.Name())
			}
		}
	case targetType != "":
		types = append(types, targetType)
	default:
		log.Fatal("--type, --env or --all-types required")
	}

	for _, t := range types {
		processType(t, envFlag)
	}
}

func handleOIDCJWK() {
	args := flag.Args()
	if len(args) != 2 {
		log.Fatal("usage: -oidc-jwk <secrets.yaml> <output.json>")
	}
	secretsPath, outPath := args[0], args[1]
	if !filepath.IsAbs(secretsPath) {
		secretsPath = filepath.Join(baseDir, secretsPath)
	}
	if !filepath.IsAbs(outPath) {
		outPath = filepath.Join(baseDir, outPath)
	}

	var secrets struct {
		Certs struct {
			K8sServiceAccount struct {
				Key string `yaml:"key"`
			} `yaml:"k8sserviceaccount"`
		} `yaml:"certs"`
	}
	loadYAML(secretsPath, &secrets)

	keyPEM, err := base64.StdEncoding.DecodeString(secrets.Certs.K8sServiceAccount.Key)
	if err != nil {
		log.Fatalf("decode service account key: %v", err)
	}
	block, _ := pem.Decode(keyPEM)
	if block == nil {
		log.Fatal("service account key is not a PEM block")
	}

	var priv crypto.PrivateKey
	switch block.Type {
	case "RSA PRIVATE KEY":
		priv, err = x509.ParsePKCS1PrivateKey(block.Bytes)
	case "EC PRIVATE KEY":
		priv, err = x509.ParseECPrivateKey(block.Bytes)
	case "PRIVATE KEY":
		priv, err = x509.ParsePKCS8PrivateKey(block.Bytes)
	default:
		log.Fatalf("unsupported PEM block type %q", block.Type)
	}
	if err != nil {
		log.Fatalf("parse service account key: %v", err)
	}

	pub := priv.(crypto.Signer).Public()
	pubDER, err := x509.MarshalPKIXPublicKey(pub)
	if err != nil {
		log.Fatalf("marshal public key: %v", err)
	}
	hash := sha256.Sum256(pubDER)
	jwk := oidcJWK{Kid: base64.RawURLEncoding.EncodeToString(hash[:])}

	switch k := pub.(type) {
	case *rsa.PublicKey:
		jwk.Use = "sig"
		jwk.Kty = "RSA"
		jwk.Alg = "RS256"
		jwk.N = base64.RawURLEncoding.EncodeToString(k.N.Bytes())
		jwk.E = base64.RawURLEncoding.EncodeToString(big.NewInt(int64(k.E)).Bytes())
	case *ecdsa.PublicKey:
		if k.Curve != elliptic.P256() {
			log.Fatal("unsupported EC curve, only P-256 is supported")
		}
		x := make([]byte, 32)
		y := make([]byte, 32)
		k.X.FillBytes(x)
		k.Y.FillBytes(y)
		jwk.Use = "sig"
		jwk.Kty = "EC"
		jwk.Alg = "ES256"
		jwk.Crv = "P-256"
		jwk.X = base64.RawURLEncoding.EncodeToString(x)
		jwk.Y = base64.RawURLEncoding.EncodeToString(y)
	default:
		log.Fatalf("unsupported service account key type %T", pub)
	}

	out, err := json.MarshalIndent(struct {
		Keys []oidcJWK `json:"keys"`
	}{[]oidcJWK{jwk}}, "", "  ")
	if err != nil {
		log.Fatalf("marshal jwks: %v", err)
	}
	out = append(out, '\n')
	if err := os.WriteFile(outPath, out, 0644); err != nil {
		log.Fatalf("write jwks: %v", err)
	}
	log.Printf("wrote %s", outPath)
}

type oidcJWK struct {
	Use string `json:"use"`
	Kty string `json:"kty"`
	Kid string `json:"kid"`
	Alg string `json:"alg"`
	N   string `json:"n,omitempty"`
	E   string `json:"e,omitempty"`
	Crv string `json:"crv,omitempty"`
	X   string `json:"x,omitempty"`
	Y   string `json:"y,omitempty"`
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

func processType(typeName, envOverride string) {
	var cfg TypeConfig
	path := filepath.Join(baseDir, "clusters", "types", typeName, "app_config.yaml")
	if _, err := os.Stat(path); os.IsNotExist(err) {
		log.Printf("[SKIP] no config for type %s", typeName)
		return
	}
	loadYAML(path, &cfg)

	apps := cfg.InstallList
	if envOverride != "" {
		var envCfg TypeConfig
		envPath := filepath.Join(baseDir, "clusters", "envs", envOverride, "app_config.yaml")
		if _, err := os.Stat(envPath); err == nil {
			loadYAML(envPath, &envCfg)
			if len(envCfg.InstallList) > 0 {
				apps = envCfg.InstallList
			}
			for k, v := range envCfg.Versions {
				cfg.Versions[k] = v
			}
		}
	}
	if targetApp != "" {
		found := false
		for _, a := range apps {
			if a == targetApp {
				found = true
				break
			}
		}
		if !found {
			if !scaffoldApp(typeName, envOverride, targetApp) {
				return
			}
			loadYAML(path, &cfg)
		}
		apps = []string{targetApp}
	}

	envs := matchingEnvs(typeName)
	if envOverride != "" {
		envs = []string{envOverride}
	}

	for _, appName := range apps {
		app, ok := baseConfig.Apps[appName]
		if !ok {
			log.Printf("[SKIP] %s not in default_app_config.yaml", appName)
			continue
		}

		version := cfg.Versions[appName]
		if version == "" {
			latest := fetchLatestVersion(app)
			if latest != "" {
				log.Printf("[ADD] %s: no pinned version for %s, using latest %s", appName, typeName, latest)
				if cfg.Versions == nil {
					cfg.Versions = map[string]string{}
				}
				cfg.Versions[appName] = latest
				saveYAML(path, cfg)
				version = latest
			}
		}
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

	var chart *chart.Chart
	if strings.HasPrefix(app.RepoURL, "oci://") {
		chart, err = pullOCIChart(app, pullVer, settings, tmpDir)
	} else {
		chart, err = pullRepoChart(app, pullVer, settings, tmpDir)
	}
	if err != nil {
		return "", err
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

func pullRepoChart(app AppDef, pullVer string, settings *cli.EnvSettings, tmpDir string) (*chart.Chart, error) {
	providers := getter.All(settings)

	repoEntry := &repo.Entry{
		Name: app.RepoName,
		URL:  app.RepoURL,
	}

	chartRepo, err := repo.NewChartRepository(repoEntry, providers)
	if err != nil {
		return nil, fmt.Errorf("new chart repo: %w", err)
	}

	idxFile, err := chartRepo.DownloadIndexFile()
	if err != nil {
		return nil, fmt.Errorf("download index: %w", err)
	}
	defer os.Remove(idxFile)

	idx, err := repo.LoadIndexFile(idxFile)
	if err != nil {
		return nil, fmt.Errorf("load index: %w", err)
	}

	cv, err := idx.Get(app.Chart, pullVer)
	if err != nil {
		return nil, fmt.Errorf("chart version %s: %w", pullVer, err)
	}

	if len(cv.URLs) == 0 {
		return nil, fmt.Errorf("no URLs for chart %s %s", app.Chart, pullVer)
	}

	chartURL := cv.URLs[0]
	if !strings.Contains(chartURL, "://") {
		baseURL := strings.TrimRight(app.RepoURL, "/")
		chartURL = baseURL + "/" + strings.TrimLeft(chartURL, "/")
	}

	g, err := providers.ByScheme(strings.SplitN(chartURL, "://", 2)[0])
	if err != nil {
		return nil, fmt.Errorf("no getter for %s: %w", chartURL, err)
	}

	buf, err := g.Get(chartURL)
	if err != nil {
		return nil, fmt.Errorf("download chart: %w", err)
	}

	chartTmp := filepath.Join(tmpDir, "chart.tgz")
	if err := os.WriteFile(chartTmp, buf.Bytes(), 0644); err != nil {
		return nil, err
	}

	return loader.Load(chartTmp)
}

func pullOCIChart(app AppDef, pullVer string, settings *cli.EnvSettings, tmpDir string) (*chart.Chart, error) {
	regClient, err := registry.NewClient(
		registry.ClientOptWriter(io.Discard),
		registry.ClientOptCredentialsFile(settings.RegistryConfig),
	)
	if err != nil {
		return nil, fmt.Errorf("registry client: %w", err)
	}

	ref := strings.TrimRight(app.RepoURL, "/")
	if !strings.HasSuffix(ref, "/"+app.Chart) {
		ref = ref + "/" + app.Chart
	}

	pull := action.NewPullWithOpts(action.WithConfig(&action.Configuration{}))
	pull.Settings = settings
	pull.Version = pullVer
	pull.DestDir = tmpDir
	pull.SetRegistryClient(regClient)

	_, err = pull.Run(ref)
	if err != nil {
		return nil, fmt.Errorf("oci pull %s: %w", ref, err)
	}

	matches, err := filepath.Glob(filepath.Join(tmpDir, "*.tgz"))
	if err != nil {
		return nil, err
	}
	if len(matches) != 1 {
		return nil, fmt.Errorf("oci pull %s: expected one chart tarball in %s, found %d", ref, tmpDir, len(matches))
	}

	return loader.Load(matches[0])
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

		writeOverlayKustomization(ovlDir, compPath, appDir)
		ensureGitkeep(filepath.Join(ovlDir, "resources"))
		ensureGitkeep(filepath.Join(ovlDir, "patches"))
		log.Printf("[OVL] %s/overlays/%s", appName, env)
	}
}

func writeOverlayKustomization(ovlDir, compPath, appDir string) {
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

	var patchPaths []string
	patchesDir := filepath.Join(ovlDir, "patches")
	if hasYAMLFiles(patchesDir) {
		entries, _ := os.ReadDir(patchesDir)
		for _, e := range entries {
			if !e.IsDir() && strings.HasSuffix(e.Name(), ".yaml") {
				patchPaths = append(patchPaths, "patches/"+e.Name())
			}
		}
	}
	appPatchesDir := filepath.Join(appDir, "patches")
	if hasYAMLFiles(appPatchesDir) {
		entries, _ := os.ReadDir(appPatchesDir)
		for _, e := range entries {
			if !e.IsDir() && strings.HasSuffix(e.Name(), ".yaml") {
				patchPaths = append(patchPaths, "../../patches/"+e.Name())
			}
		}
	}
	if len(patchPaths) > 0 {
		sort.Strings(patchPaths)
		buf.WriteString("patches:\n")
		for _, p := range patchPaths {
			buf.WriteString(fmt.Sprintf("  - path: %s\n", p))
		}
	}

	kPath := filepath.Join(ovlDir, "kustomization.yaml")
	if data, err := os.ReadFile(kPath); err == nil && bytes.Equal(data, buf.Bytes()) {
		return
	}
	os.WriteFile(kPath, buf.Bytes(), 0644)
}

// ensureGitkeep creates .gitkeep in dir if it has no YAML resources, and
// removes it once real YAML files land in the dir.
func ensureGitkeep(dir string) {
	os.MkdirAll(dir, 0755)
	has := false
	entries, err := os.ReadDir(dir)
	if err == nil {
		for _, e := range entries {
			if !e.IsDir() && strings.HasSuffix(e.Name(), ".yaml") && e.Name() != "kustomization.yaml" {
				has = true
				break
			}
		}
	}
	kPath := filepath.Join(dir, ".gitkeep")
	if has {
		os.Remove(kPath)
	} else {
		os.WriteFile(kPath, nil, 0644)
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

	kPath := filepath.Join(dir, "kustomization.yaml")
	data, err := os.ReadFile(kPath)
	if err != nil {
		var buf bytes.Buffer
		buf.WriteString("apiVersion: kustomize.config.k8s.io/v1beta1\nkind: Kustomization\nresources:\n")
		for _, f := range files {
			buf.WriteString(fmt.Sprintf("  - %s\n", f))
		}
		os.WriteFile(kPath, buf.Bytes(), 0644)
		return
	}

	var doc yaml.Node
	if err := yaml.Unmarshal(data, &doc); err != nil {
		return
	}
	root := &doc
	if doc.Kind == yaml.DocumentNode && len(doc.Content) > 0 {
		root = doc.Content[0]
	}
	if root.Kind == yaml.MappingNode {
		for i := 0; i+1 < len(root.Content); i += 2 {
			if root.Content[i].Value == "resources" {
				resNode := &yaml.Node{Kind: yaml.SequenceNode, Tag: "!!seq"}
				for _, f := range files {
					resNode.Content = append(resNode.Content, &yaml.Node{Kind: yaml.ScalarNode, Tag: "!!str", Value: f})
				}
				root.Content[i+1] = resNode
				break
			}
		}
	}
	var buf bytes.Buffer
	enc := yaml.NewEncoder(&buf)
	enc.SetIndent(2)
	if err := enc.Encode(&doc); err != nil {
		return
	}
	enc.Close()
	if bytes.Equal(buf.Bytes(), data) {
		return
	}
	os.WriteFile(kPath, buf.Bytes(), 0644)
}

func handleSync() {
	entries, err := os.ReadDir(manifestsDir)
	if err != nil {
		return
	}
	apps := make([]string, 0, len(entries))
	for _, e := range entries {
		if e.IsDir() {
			apps = append(apps, e.Name())
		}
	}
	sort.Strings(apps)
	if targetApp != "" {
		found := false
		for _, a := range apps {
			if a == targetApp {
				apps = []string{targetApp}
				found = true
				break
			}
		}
		if !found {
			log.Printf("[SYNC] %s not found under manifests/", targetApp)
			return
		}
	}
	for _, appName := range apps {
		syncApp(appName)
	}
}

func syncApp(appName string) {
	appDir := filepath.Join(manifestsDir, appName)
	if _, err := os.Stat(appDir); os.IsNotExist(err) {
		return
	}

	resPath := filepath.Join(appDir, "resources")
	if hasYAMLFiles(resPath) {
		genBaseKustomization(resPath)
	}
	ensureGitkeep(resPath)
	ensureGitkeep(filepath.Join(appDir, "patches"))

	ovlRoot := filepath.Join(appDir, "overlays")
	ovls, err := os.ReadDir(ovlRoot)
	if err != nil {
		return
	}
	for _, o := range ovls {
		if !o.IsDir() {
			continue
		}
		ovlDir := filepath.Join(ovlRoot, o.Name())
		compRef := extractCompRef(filepath.Join(ovlDir, "kustomization.yaml"))
		if compRef == "" {
			log.Printf("[SYNC] %s/overlays/%s: no components ref found, skipping", appName, o.Name())
			continue
		}
		writeOverlayKustomization(ovlDir, compRef, appDir)
		ensureGitkeep(filepath.Join(ovlDir, "resources"))
		ensureGitkeep(filepath.Join(ovlDir, "patches"))
	}
	log.Printf("[SYNC] %s", appName)
}

func extractCompRef(kPath string) string {
	data, err := os.ReadFile(kPath)
	if err != nil {
		return ""
	}
	scanner := bufio.NewScanner(bytes.NewReader(data))
	for scanner.Scan() {
		line := strings.TrimSpace(scanner.Text())
		if strings.HasPrefix(line, "- ../../components/") {
			return strings.TrimPrefix(line, "- ")
		}
	}
	return ""
}

func handleIngest() {
	if _, ok := baseConfig.Apps[ingestApp]; !ok {
		log.Fatalf("[SKIP] %s not in default_app_config.yaml; add its source definition there first", ingestApp)
	}
	appDir := filepath.Join(manifestsDir, ingestApp)
	os.MkdirAll(appDir, 0755)

	var dir string
	if envFlag != "" {
		var ec EnvConfig
		envCfgPath := filepath.Join(baseDir, "clusters", "envs", envFlag, "config.yaml")
		if _, err := os.Stat(envCfgPath); os.IsNotExist(err) {
			log.Fatalf("no config for env %s (expected %s)", envFlag, envCfgPath)
		}
		loadYAML(envCfgPath, &ec)
		if ec.Type == "" {
			log.Fatalf("env %s has no type in %s", envFlag, envCfgPath)
		}
		dir = filepath.Join(appDir, "overlays", envFlag, "resources")
	} else {
		dir = filepath.Join(appDir, "resources")
	}
	os.MkdirAll(dir, 0755)

	var input []byte
	if flag.NArg() > 0 {
		for _, f := range flag.Args() {
			data, err := os.ReadFile(f)
			if err != nil {
				log.Fatalf("read %s: %v", f, err)
			}
			input = append(input, data...)
		}
	} else {
		var err error
		input, err = io.ReadAll(os.Stdin)
		if err != nil {
			log.Fatalf("read stdin: %v", err)
		}
	}
	if len(strings.TrimSpace(string(input))) == 0 {
		log.Fatal("no input: pipe YAML to stdin or pass file arguments")
	}

	ingestYAML(input, dir)
	ensureGitkeep(dir)
	syncApp(ingestApp)
}

// ingestYAML splits multi-doc YAML, strips comments (block-scalar aware),
// drops Namespace resources, and appends each doc to {kind}.yaml in dir.
func ingestYAML(data []byte, dir string) {
	scanner := bufio.NewScanner(bytes.NewReader(data))
	scanner.Buffer(make([]byte, 0, 64*1024), 1024*1024)

	var currentDoc []string
	var kind string

	flush := func() {
		if len(currentDoc) == 0 || kind == "" || kind == "Namespace" {
			currentDoc, kind = nil, ""
			return
		}
		cleaned := cleanDocBlanks(stripCommentLines(currentDoc))
		content := strings.TrimSpace(strings.Join(cleaned, "\n"))
		if content == "" {
			currentDoc, kind = nil, ""
			return
		}
		fpath := filepath.Join(dir, strings.ToLower(kind)+".yaml")
		f, err := os.OpenFile(fpath, os.O_APPEND|os.O_CREATE|os.O_WRONLY, 0644)
		if err != nil {
			log.Printf("[INGEST] %s: %v", fpath, err)
			currentDoc, kind = nil, ""
			return
		}
		f.WriteString("---\n" + content + "\n")
		f.Close()
		log.Printf("[INGEST] %s", fpath)
		currentDoc, kind = nil, ""
	}

	for scanner.Scan() {
		line := scanner.Text()
		if strings.HasPrefix(line, "---") {
			flush()
			continue
		}
		trimmed := strings.TrimSpace(line)
		if strings.HasPrefix(line, "kind:") && kind == "" {
			kind = strings.Trim(strings.TrimSpace(strings.TrimPrefix(trimmed, "kind:")), `"'`)
		}
		currentDoc = append(currentDoc, strings.TrimRight(line, " \t"))
	}
	flush()
}

func stripCommentLines(lines []string) []string {
	var out []string
	inBlock := false
	blockIndent := 0
	for _, line := range lines {
		if inBlock {
			if strings.TrimSpace(line) == "" || indentOf(line) > blockIndent {
				out = append(out, line)
				continue
			}
			inBlock = false
		}
		trimmed := strings.TrimSpace(line)
		if strings.HasPrefix(trimmed, "#") {
			continue
		}
		if isBlockScalarHeader(line) {
			inBlock = true
			blockIndent = indentOf(line)
		}
		out = append(out, line)
	}
	return out
}

func indentOf(line string) int {
	return len(line) - len(strings.TrimLeft(line, " \t"))
}

func scaffoldApp(typeName, envOverride, appName string) bool {
	app, ok := baseConfig.Apps[appName]
	if !ok {
		log.Printf("[SKIP] %s not in default_app_config.yaml; add its source definition there first", appName)
		return false
	}

	typePath := filepath.Join(baseDir, "clusters", "types", typeName, "app_config.yaml")
	var typeCfg TypeConfig
	loadYAML(typePath, &typeCfg)
	if typeCfg.Versions == nil {
		typeCfg.Versions = map[string]string{}
	}

	modified := false
	if typeCfg.Versions[appName] == "" {
		latest := fetchLatestVersion(app)
		if latest == "" {
			log.Printf("[SKIP] %s: could not determine latest version; pin it manually in %s", appName, typePath)
			return false
		}
		typeCfg.Versions[appName] = latest
		log.Printf("[ADD] %s: pinned version %s for %s", appName, latest, typeName)
		modified = true
	}

	if envOverride != "" {
		envPath := filepath.Join(baseDir, "clusters", "envs", envOverride, "app_config.yaml")
		var envCfg TypeConfig
		if _, err := os.Stat(envPath); err != nil {
			envCfg = TypeConfig{InstallList: []string{appName}}
		} else {
			loadYAML(envPath, &envCfg)
			envCfg.InstallList = append(envCfg.InstallList, appName)
		}
		sort.Strings(envCfg.InstallList)
		saveYAML(envPath, envCfg)
		log.Printf("[ADD] %s added to env %s install list", appName, envOverride)
	} else {
		typeCfg.InstallList = append(typeCfg.InstallList, appName)
		sort.Strings(typeCfg.InstallList)
		log.Printf("[ADD] %s added to type %s install list", appName, typeName)
		modified = true
	}

	if modified {
		saveYAML(typePath, typeCfg)
	}
	createAppSkeleton(appName, typeName, envOverride, app)
	return true
}

// createAppSkeleton creates the directory layout, values placeholders (helm
// apps only), and .gitkeep files for a brand new app. Existing apps are
// left untouched.
func createAppSkeleton(appName, typeName, envOverride string, app AppDef) {
	appDir := filepath.Join(manifestsDir, appName)
	if _, err := os.Stat(appDir); err == nil {
		return
	}

	if app.Type == "helm" {
		valsDir := filepath.Join(appDir, "values")
		os.MkdirAll(valsDir, 0755)
		os.WriteFile(filepath.Join(valsDir, "default.yaml"), []byte("# Helm values for "+appName+", shared across types\n"), 0644)
		os.WriteFile(filepath.Join(valsDir, typeName+".yaml"), []byte("# Helm values for "+appName+" on "+typeName+"\n"), 0644)
	}

	var envs []string
	if envOverride != "" {
		envs = []string{envOverride}
	} else {
		envs = matchingEnvs(typeName)
	}
	overlays := make([]string, 0, len(envs))
	for _, env := range envs {
		ovlDir := filepath.Join(appDir, "overlays", env)
		ensureGitkeep(filepath.Join(ovlDir, "patches"))
		ensureGitkeep(filepath.Join(ovlDir, "resources"))
		overlays = append(overlays, env)
	}
	ensureGitkeep(filepath.Join(appDir, "resources"))
	ensureGitkeep(filepath.Join(appDir, "patches"))
	log.Printf("[ADD] %s: created skeleton (overlays: %s, resources/, patches/)", appName, strings.Join(overlays, ","))
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
			var result struct {
				TagName string `json:"tag_name"`
			}
			json.NewDecoder(resp.Body).Decode(&result)
			return result.TagName
		}
	}
	if app.Type == "helm" {
		if strings.HasPrefix(app.RepoURL, "oci://") {
			return fetchOCILatestVersion(app)
		}
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

func fetchOCILatestVersion(app AppDef) string {
	settings := cli.New()
	regClient, err := registry.NewClient(
		registry.ClientOptWriter(io.Discard),
		registry.ClientOptCredentialsFile(settings.RegistryConfig),
	)
	if err != nil {
		return ""
	}

	ref := strings.TrimPrefix(app.RepoURL, "oci://")
	ref = strings.TrimRight(ref, "/")
	if !strings.HasSuffix(ref, "/"+app.Chart) {
		ref = ref + "/" + app.Chart
	}

	tags, err := regClient.Tags(ref)
	if err != nil {
		return ""
	}

	var latest *semver.Version
	for _, tag := range tags {
		v, err := semver.StrictNewVersion(tag)
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
