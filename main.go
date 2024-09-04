package main

import "fmt"
import "github.com/ericlagergren/decimal"

func main() {
    fmt.Println("Hello, World!")

	x := decimal.New(1, 0)
	var g1 decimal.Big
	g1.Add(x, x)
}