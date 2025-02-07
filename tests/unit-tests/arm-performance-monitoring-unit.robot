*** Variables ***
${PLATFORM}                         SEPARATOR=
...                                 """                                                    ${\n}
...                                 cpu: CPU.ARMv7A @ sysbus                               ${\n}
...                                 ${SPACE*4}cpuType: "cortex-a9"                         ${\n}
...                                                                                        ${\n}
...                                 pmu: Miscellaneous.ArmPerformanceMonitoringUnit @ cpu  ${\n}
...                                                                                        ${\n}
...                                 memory: Memory.MappedMemory @ sysbus 0x0               ${\n}
...                                 ${SPACE*4}size: 0x20000                                ${\n}
...                                 """

${BOGUS_EVENT_1}                    0x1
${BOGUS_EVENT_2}                    0xAB
${SOFTWARE_INCREMENT_EVENT}         0x00
${INSTRUCTIONS_EVENT}               0x8
${CYCLES_EVENT}                     0x11

*** Keywords ***
Create Machine
    Execute Command                 using sysbus
    Execute Command                 mach create
    Execute Command                 machine LoadPlatformDescriptionFromString ${PLATFORM}

    # Create infinite loop
    Execute Command                 sysbus WriteDoubleWord 0x1000 0xE320F000  # nop
    Execute Command                 sysbus WriteDoubleWord 0x1004 0xEAFFFFFD  # b to 0x1000

    Execute Command                 cpu PC 0x1000

Set Register Bits
    [Arguments]                     ${regName}  ${value}
    ${enabledCounters}=             Execute Command  cpu.pmu GetRegister ${regName}
    ${mask}=                        Evaluate  hex(int($enabledCounters, 16) | int($value))

    Execute Command                 cpu.pmu SetRegister ${regName} ${mask}

Clear Register Bits
    [Arguments]                     ${regName}  ${value}
    ${enabledCounters}=             Execute Command  cpu.pmu GetRegister ${regName}
    ${mask}=                        Evaluate  hex(int($enabledCounters, 16) & ~int($value))

    Execute Command                 cpu.pmu SetRegister ${regName} ${mask}

Enable PMU
    Set Register Bits               "PMCR"  1

Disable PMU
    Clear Register Bits             "PMCR"  1

Reset PMU Counters
    Set Register Bits               "PMCR"  2

Reset PMU Cycle Counter
    Set Register Bits               "PMCR"  3

Set Cycles Divisor 64
    [Arguments]                     ${divisor}
    IF  $divisor
        Set Register Bits               "PMCR"  9
    ELSE
        Clear Register Bits             "PMCR"  9
    END

Enable PMU Counter
    [Arguments]                     ${counter}
    ${value}=                       Evaluate  (1 << int($counter))

    Set Register Bits               "PMCNTENSET"  ${value}

Disable PMU Counter
    [Arguments]                     ${counter}
    ${value}=                       Evaluate  (1 << int($counter))

    Execute Command                 cpu.pmu SetRegister "PMCNTENCLR" ${value}

Enable Overflow Interrupt For PMU Counter
    [Arguments]                     ${counter}
    ${value}=                       Evaluate  (1 << int($counter))

    Execute Command                 cpu.pmu SetRegister "PMINTENSET" ${value}

Disable Overflow Interrupt For PMU Counter
    [Arguments]                     ${counter}
    ${value}=                       Evaluate  (1 << int($counter))

    Execute Command                 cpu.pmu SetRegister "PMINTENCLR"  ${value}

Increment Software PMU Counter
    [Arguments]                     ${counter}
    ${value}=                       Evaluate  (1 << int($counter))

    Execute Command                 cpu.pmu SetRegister "PMSWINC" ${value}

Assert PMU Counter Is Equal To
    [Arguments]                     ${counter}  ${value}
    ${cnt}=                         Execute Command  cpu.pmu GetCounterValue ${counter}

    Should Be Equal As Integers     ${cnt}  ${value}

Assert Executed Instructions Equal To
    [Arguments]                     ${value}
    ${executedInstructions}=        Execute Command  cpu ExecutedInstructions

    Should Be Equal As Integers     ${executedInstructions}  ${value}

Assert PMU Cycle Counter Equal To
    [Arguments]                     ${value}
    ${cycles}=                      Execute Command  cpu.pmu GetCycleCounterValue

    Should Be Equal As Integers     ${cycles}  ${value}

Assert PMU IRQ Is Set
    ${irqState}=                    Execute Command  cpu.pmu IRQ
    Should Contain                  ${irqState}  GPIO: set

Assert PMU IRQ Is Unset
    ${irqState}=                    Execute Command  cpu.pmu IRQ
    Should Contain                  ${irqState}  GPIO: unset

*** Test Cases ***
Should Count Cycles
    Create Machine

    Enable PMU
    Enable PMU Counter              31  # Cycle counter

    Execute Command                 emulation RunFor "00:00:01.12"

    # Given a known PerformanceInMIPS, it can be assumed that 112 000 000 instructions have been executed
    Assert PMU Cycle Counter Equal To  112 000 000
    Assert Executed Instructions Equal To  112 000 000

Should Count Cycles With Divisor
    Create Machine
    Enable PMU Counter              31  # Cycle counter
    Enable PMU
    Set Cycles Divisor 64           ${True}

    Execute Command                 emulation RunFor "00:00:00.01"
    Assert Executed Instructions Equal To  1000000
    Assert PMU Cycle Counter Equal To  15625

    Set Cycles Divisor 64           ${False}

    Execute Command                 emulation RunFor "00:00:00.01"
    Assert Executed Instructions Equal To  2000000
    Assert PMU Cycle Counter Equal To  1015625

Should Program PMU Counter To Count Cycles
    Create Machine

    Enable PMU
    Execute Command                 cpu.pmu SetCounterEvent 0 ${CYCLES_EVENT}
    Enable PMU Counter              0

    Execute Command                 emulation RunFor "00:00:01.12"

    # As above, given PerformanceInMIPS, we know how many instructions to expect
    # One cycle is equal to one instruction, this is not a mistake
    Assert Executed Instructions Equal To  112 000 000
    Assert PMU Counter Is Equal To  0  112 000 000

    # Now, an instruction should be equal to 2 cycles
    # Currently, it is needed to disable and then reenable/reset the counter, either in Monitor or with CP15 instructions
    # if "CyclesPerInstruction" value changes at runtime
    Disable PMU Counter             0
    Execute Command                 cpu CyclesPerInstruction 2
    Enable PMU Counter              0
    Execute Command                 emulation RunFor "00:00:00.01"

    # Executed 1 000 000 instructions, so 2 000 000 cycles
    Assert Executed Instructions Equal To  113 000 000
    Assert PMU Counter Is Equal To  0  114 000 000

Should Program PMU Counter To Count Instructions
    Create Machine

    Enable PMU
    Execute Command                 cpu.pmu SetCounterEvent 0 ${INSTRUCTIONS_EVENT}
    Enable PMU Counter              0

    Execute Command                 emulation RunFor "00:00:01.12"
    Assert Executed Instructions Equal To  112 000 000
    Assert PMU Counter Is Equal To  0  112 000 000

    Provides                        program-counter

Should Reset PMU counters
    Requires                        program-counter

    Assert PMU Counter Is Equal To  0  112 000 000
    Reset PMU Counters
    Assert PMU Counter Is Equal To  0  0

Should Kick Software Increment
    Create Machine

    # Configure PMU counters, only Counter 0 subscribes to Software Increment event, Counter 1 subscribes to non-implemented event
    # So only Counter 0 is expected to be incremented
    Execute Command                 cpu.pmu SetCounterEvent 0 ${SOFTWARE_INCREMENT_EVENT}
    Execute Command                 cpu.pmu SetCounterEvent 1 ${BOGUS_EVENT_1}

    # Verify the configured events by reading their event ids
    ${ev1}=                         Execute Command  cpu.pmu GetCounterEvent 1
    ${ev0}=                         Execute Command  cpu.pmu GetCounterEvent 0
    Should Be Equal As Integers     ${ev1}  1
    Should Be Equal As Integers     ${ev0}  0

    Increment Software PMU Counter  0
    Increment Software PMU Counter  1

    # Counters and PMU are disabled, should not count
    Assert PMU Counter Is Equal To  0  0
    Assert PMU Counter Is Equal To  1  0

    Enable PMU Counter              0

    Increment Software PMU Counter  1
    Increment Software PMU Counter  0

    # Still not counting, PMU is not enabled
    Assert PMU Counter Is Equal To  0  0
    Assert PMU Counter Is Equal To  1  0
    Enable PMU

    Increment Software PMU Counter  0
    Increment Software PMU Counter  1

    # PMU Counter 1 is not a Software Increment, so it shouldn't increment at all
    # Counter 0 is incremented only once, after "Enable PMU". Previous increments were invalid, since PMU was disabled
    Assert PMU Counter Is Equal To  0  1
    Assert PMU Counter Is Equal To  1  0

Should Respect PMU Counter Pasue And Resume
    Create Machine
    Enable PMU

    Execute Command                 cpu.pmu SetCounterEvent 1 ${CYCLES_EVENT}
    Enable PMU Counter              1
    Execute Command                 emulation RunFor "00:00:00.01"

    Assert PMU Counter Is Equal To  1  1000000
    Assert Executed Instructions Equal To  1000000

    # Shouldn't count with disabled PMU
    Disable PMU
    Execute Command                 emulation RunFor "00:00:00.01"

    Assert PMU Counter Is Equal To  1  1000000
    Assert Executed Instructions Equal To  2000000

    Enable PMU
    Execute Command                 emulation RunFor "00:00:00.01"

    Assert PMU Counter Is Equal To  1  2000000
    Assert Executed Instructions Equal To  3000000

    # Shouldn't count when the counter is disabled
    Disable PMU Counter             1
    Execute Command                 emulation RunFor "00:00:00.01"

    Assert PMU Counter Is Equal To  1  2000000
    Assert Executed Instructions Equal To  4000000

    Enable PMU Counter              1
    Execute Command                 emulation RunFor "00:00:00.01"

    Assert PMU Counter Is Equal To  1  3000000
    Assert Executed Instructions Equal To  5000000

Should Trigger Cycles Overflow
    Create Machine

    Enable PMU

    ## Counter 2
    # The performance in MIPS is known, so it's possible to calculate the exact moment the counter should overflow
    # Configure counter, so after 3 000 000 instructions it should have overflowed and have the value 2 stored
    # so it's set to "UINT32_MAX - value + 3"
    Execute Command                 cpu.pmu SetCounterEvent 2 ${CYCLES_EVENT}
    Execute Command                 cpu.pmu SetCounterValue 2 0xFFD23942
    Enable Overflow Interrupt For PMU Counter  2
    Enable PMU Counter              2

    ## Counter 1
    Execute Command                 cpu.pmu SetCounterEvent 1 ${CYCLES_EVENT}
    # expected to execute 1 000 000 instructions, so load "UINT32_MAX - value" to counter
    # it is expected to overflow one instruction after
    Execute Command                 cpu.pmu SetCounterValue 1 0xFFF0BDBF
    Enable Overflow Interrupt For PMU Counter  1
    Enable PMU Counter              1

    # See that it didn't overflow too soon
    Execute Command                 emulation RunFor "00:00:00.01"
    Assert Executed Instructions Equal To  1000000
    # The value is counter's base value "0xFFF0BDBF" + 1 000 000 expected instructions to execute
    Assert PMU Counter Is Equal To  1  0xFFFFFFFF
    ${overflowStatus}=              Execute Command  cpu.pmu GetRegister "PMOVSR"
    Should Be Equal As Integers     ${overflowStatus}  0
    Assert PMU IRQ Is Unset

    # It will overflow 1 instruction after, we now execute 100 000, so overflow bit has to be set
    Execute Command                 emulation RunFor "00:00:00.001"
    ${overflowStatus}=              Execute Command  cpu.pmu GetRegister "PMOVSR"
    Should Be Equal As Integers     ${overflowStatus}  2  # second counter (Counter number 1)
    Assert PMU IRQ Is Set

    Provides                        cycles-overflow

Should Resume Execution After Cycles Overflow
    Requires                        cycles-overflow

    Execute Command                 emulation RunFor "00:00:00.01"
    Assert Executed Instructions Equal To  2100000
    # instructions are counted from 0 after overflow, so instead from 1 000 000 + 100 000 subtract 1
    Assert PMU Counter Is Equal To  1  1099999

    Provides                        resumed-after-overflow

Should Overflow Second Time
    Requires                        resumed-after-overflow
    # Clear overflow bit for counter 1
    Execute Command                 cpu.pmu SetRegister "PMOVSR" 0x2

    Execute Command                 emulation RunFor "00:00:00.009"
    Assert Executed Instructions Equal To  3000000
    Assert PMU Counter Is Equal To  2  2

    ${overflowStatus}=              Execute Command  cpu.pmu GetRegister "PMOVSR"
    Should Be Equal As Integers     ${overflowStatus}  4  # counter 2 overflowed

Should Increment Bogus Event From Monitor
    # The event is unimplemented, and there will be warnings in the logs
    # but still can be used it in a test scenario
    Create Machine

    Enable PMU
    Execute Command                 cpu.pmu SetCounterEvent 1 ${BOGUS_EVENT_2}
    Enable PMU Counter              1

    Execute Command                 cpu.pmu BroadcastEvent ${BOGUS_EVENT_2} 5
    Assert PMU Counter Is Equal To  1  5

    # now, let's overflow
    Enable Overflow Interrupt For PMU Counter  1
    Execute Command                 cpu.pmu BroadcastEvent ${BOGUS_EVENT_2} 0xFFFFFFFF
    Assert PMU Counter Is Equal To  1  4

    ${overflowStatus}=              Execute Command  cpu.pmu GetRegister "PMOVSR"
    Should Be Equal As Integers     ${overflowStatus}  2  # second counter (Counter number 1)
    Assert PMU IRQ Is Set
