package main

import (
	"context"
	"fmt"
	"log"
	"net/http"
	"strings"

	"github.com/grpc-ecosystem/grpc-gateway/v2/runtime"
	sso "github.com/lunyashon/protobuf/auth/gen/go/sso/v1"
	"google.golang.org/grpc"
	"google.golang.org/grpc/credentials/insecure"
)

func main() {
	gRPCHundler()
}

func gRPCHundler() {

	mux := runtime.NewServeMux(
		runtime.WithIncomingHeaderMatcher(func(key string) (string, bool) {
			k := strings.ToLower(key)
			switch k {
			case "x-real-ip", "x-forwarded-for", "cf-connecting-ip", "x-client-ip":
				return k, true
			default:
				return runtime.DefaultHeaderMatcher(key)
			}
		}),
	)

	opts := []grpc.DialOption{
		grpc.WithTransportCredentials(insecure.NewCredentials()),
	}

	if err := sso.RegisterAuthHandlerFromEndpoint(
		context.Background(),
		mux,
		"localhost:50551",
		opts,
	); err != nil {
		log.Fatalf("err in register endpoint %v", err)
	}

	fmt.Println("Server start in port 50550")
	log.Fatal(http.ListenAndServe(":50550", mux))
}
