#!/bin/sh

stage() {
    STAGE="$1"
    echo
    echo starting stage: $STAGE
}

end_stage() {
    if [ $? -ne 0 ]; then
        >&2 echo error at \'$STAGE\'
        exit 1
    fi
    echo finished stage: $STAGE ✓
    echo
}


module() {
    mkdir -p /caddy
    cd /caddy # build dir
    cat > go.mod <<EOF
    module caddy

    go 1.13

    require (
        github.com/caddyserver/caddy v1.0.5
        github.com/captncraig/caddy-realip v0.0.0-20190710144553-6df827e22ab8
        github.com/captncraig/cors v0.0.0-20190703115713-e80254a89df1
        github.com/echocat/caddy-filter v0.14.0
        github.com/epicagency/caddy-expires v1.1.1
        github.com/go-acme/lego/v3 v3.7.0
        github.com/hacdias/caddy-minify v1.0.2
        github.com/nicolasazrak/caddy-cache v0.3.4
        github.com/pquerna/cachecontrol v0.0.0-20180517163645-1555304b9b35 // indirect
        github.com/caddyserver/forwardproxy v0.0.0-20190707023537-05540a763b63
        github.com/mastercactapus/caddy-proxyprotocol v0.0.3
    )
EOF
    # main and telemetry
    cat > main.go <<EOF
    package main

    import (
        "net/http"
        "regexp"
        "strconv"
        "strings"
        "github.com/caddyserver/caddy"
        "github.com/caddyserver/caddy/caddy/caddymain"
        "github.com/caddyserver/caddy/caddyhttp/httpserver"
        "github.com/captncraig/cors"
        // plug in plugins here, for example:
        // _ "import/path/here"
        "errors"

        "github.com/caddyserver/caddy/caddytls"
        "github.com/go-acme/lego/v3/providers/dns/dnspod"
        _ "github.com/mastercactapus/caddy-proxyprotocol"
        _ "github.com/caddyserver/forwardproxy"
        _ "github.com/caddyserver/dnsproviders/cloudflare"
        _ "github.com/echocat/caddy-filter"
        _ "github.com/nicolasazrak/caddy-cache"
        _ "github.com/hacdias/caddy-minify"
        _ "github.com/epicagency/caddy-expires"
        _ "github.com/captncraig/caddy-realip"
    )

    func main() {
        caddytls.RegisterDNSProvider("dnspod", NewDNSProvider)
        caddy.RegisterPlugin("cors", caddy.Plugin{
            ServerType: "http",
            Action:     setup,
        })
        // optional: disable telemetry
        caddymain.EnableTelemetry = false
        caddymain.Run()
    }

    func NewDNSProvider(credentials ...string) (caddytls.ChallengeProvider, error) {
        switch len(credentials) {
        case 0:
            return dnspod.NewDNSProvider()
        case 1:
            config := dnspod.NewDefaultConfig()
            config.LoginToken = credentials[0]
            return dnspod.NewDNSProviderConfig(config)
        default:
            return nil, errors.New("invalid credentials length")
        }
    }

    type corsRule struct {
        Conf *cors.Config
        Path string
    }

    func setup(c *caddy.Controller) error {
        rules, err := parseRules(c)
        if err != nil {
            return err
        }
        siteConfig := httpserver.GetConfig(c)
        siteConfig.AddMiddleware(func(next httpserver.Handler) httpserver.Handler {
            return httpserver.HandlerFunc(func(w http.ResponseWriter, r *http.Request) (int, error) {
                for _, rule := range rules {
                    if httpserver.Path(r.URL.Path).Matches(rule.Path) {
                        rule.Conf.HandleRequest(w, r)
                        if cors.IsPreflight(r) {
                            return 200, nil
                        }
                        break
                    }
                }
                return next.ServeHTTP(w, r)
            })
        })
        return nil
    }

    func parseRules(c *caddy.Controller) ([]*corsRule, error) {
        rules := []*corsRule{}

        for c.Next() {
            rule := &corsRule{Path: "/", Conf: cors.Default()}
            args := c.RemainingArgs()

            anyOrigins := false
            if len(args) > 0 {
                rule.Path = args[0]
            }
            for i := 1; i < len(args); i++ {
                if !anyOrigins {
                    rule.Conf.AllowedOrigins = nil
                }
                rule.Conf.AllowedOrigins = append(rule.Conf.AllowedOrigins, strings.Split(args[i], ",")...)
                anyOrigins = true
            }
            for c.NextBlock() {
                switch c.Val() {
                case "origin":
                    if !anyOrigins {
                        rule.Conf.AllowedOrigins = nil
                    }
                    args := c.RemainingArgs()
                    for _, domain := range args {
                        rule.Conf.AllowedOrigins = append(rule.Conf.AllowedOrigins, strings.Split(domain, ",")...)
                    }
                    anyOrigins = true
                case "origin_regexp":
                    if arg, err := singleArg(c, "origin_regexp"); err != nil {
                        return nil, err
                    } else {
                        r, err := regexp.Compile(arg)

                        if err != nil {
                            return nil, c.Errf("could no compile regexp: %s", err)
                        }

                        if !anyOrigins {
                            rule.Conf.AllowedOrigins = nil
                            anyOrigins = true
                        }

                        rule.Conf.OriginRegexps = append(rule.Conf.OriginRegexps, r)
                    }
                case "methods":
                    if arg, err := singleArg(c, "methods"); err != nil {
                        return nil, err
                    } else {
                        rule.Conf.AllowedMethods = arg
                    }
                case "allow_credentials":
                    if arg, err := singleArg(c, "allow_credentials"); err != nil {
                        return nil, err
                    } else {
                        var b bool
                        if arg == "true" {
                            b = true
                        } else if arg != "false" {
                            return nil, c.Errf("allow_credentials must be true or false.")
                        }
                        rule.Conf.AllowCredentials = &b
                    }
                case "max_age":
                    if arg, err := singleArg(c, "max_age"); err != nil {
                        return nil, err
                    } else {
                        i, err := strconv.Atoi(arg)
                        if err != nil {
                            return nil, c.Err("max_age must be valid int")
                        }
                        rule.Conf.MaxAge = i
                    }
                case "allowed_headers":
                    if arg, err := singleArg(c, "allowed_headers"); err != nil {
                        return nil, err
                    } else {
                        rule.Conf.AllowedHeaders = arg
                    }
                case "exposed_headers":
                    if arg, err := singleArg(c, "exposed_headers"); err != nil {
                        return nil, err
                    } else {
                        rule.Conf.ExposedHeaders = arg
                    }
                default:
                    return nil, c.Errf("Unknown cors config item: %s", c.Val())
                }
            }
            rules = append(rules, rule)
        }
        return rules, nil
    }

    func singleArg(c *caddy.Controller, desc string) (string, error) {
        args := c.RemainingArgs()
        if len(args) != 1 {
            return "", c.Errf("%s expects exactly one argument", desc)
        }
        return args[0], nil
    }
EOF

    # setup module
    # go mod init caddy
    go get github.com/caddyserver/caddy
}

# check for modules support
# export GO111MODULE=on

# add plugins and telemetry
stage "customising plugins and telemetry"
module
end_stage

# build
stage "building caddy"
go build -o caddy
end_stage

# copy binary
stage "copying binary"
mkdir -p /install \
    && mv caddy /install \
    && /install/caddy -version
end_stage

echo "installed caddy version at /install/caddy"
