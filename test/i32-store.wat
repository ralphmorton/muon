(module
  (memory $memory 1)

  (func (export "store_in_mem") (param $num i32)
    i32.const 0
    local.get $num

    i32.store
  )
)
