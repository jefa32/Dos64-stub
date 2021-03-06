
;--- DOS stub program which switches to long-mode and back.
;--- Note: requires at least JWasm v2.
;--- Also: needs a 64bit cpu in real-mode to run.
;--- To create the binary enter:
;---  JWasm -mz DOS64stb.asm

    .x64p
    option casemap:none

    include peimage.inc
    include dpmi.inc

    option MZ:sizeof IMAGE_DOS_HEADER   ;set min size of MZ header if jwasm's -mz option is used

?MPIC equ 78h
?SPIC equ 70h	; isn't changed
?IDT32 equ 0	;1=setup a IDT in legacy protected-mode (needed if an exc occurs there)

EMM struct  ;XMS block move help struct
_size  dd ?
srchdl dw ?
srcofs dd ?
dsthdl dw ?
dstofs dd ?
EMM ends

@stosw macro
    db 67h
    stosw
endm
@stosd macro
    db 67h
    stosd
endm
@lodsw macro
    db 67h
    lodsw
endm
@lodsd macro
    db 67h
    lodsd
endm
@movsw macro
    db 67h
    movsw
endm
@rep macro cmd
    db 0f3h,67h
    cmd
endm
@lgdt macro addr
    db 66h
    lgdt addr
endm
@lidt macro addr
    db 66h
    lidt addr
endm

@wait macro
local lbl1
;    push ax
lbl1:
    in al,64h       ;key from keyboard arrived?
    test al,1
    jz lbl1
    in al,60h
    cmp al,81h      ;wait for ESC released
    jnz lbl1
;    pop ax
endm

@errorexit macro text
local sym
    mov dx,offset sym
    mov ah,9
    int 21h
    jmp exit
sym db text,13,10,'$'
endm

@fatexit macro text
local sym
    mov dx,offset sym
    mov ah,9
    int 21h
    mov ah,4Ch
    int 21h
sym db text,13,10,'$'
endm

;--- 16bit start/exit code

SEL_CODE64 equ 1*8
SEL_FLAT   equ 2*8
SEL_CODE16 equ 3*8
SEL_DATA16 equ 4*8

_TEXT16 segment use16 para public 'CODE'

    assume ds:_TEXT16
    assume es:_TEXT16

GDTR label fword        ; Global Descriptors Table Register
    dw 5*8-1            ; limit of GDT (size minus one)
    dd offset GDT       ; linear address of GDT
IDTR label fword        ; IDTR in long mode
    dw 256*16-1         ; limit of IDT (size minus one)
    dd 0                ; linear address of IDT
if ?IDT32
IDTR32 label fword      ; IDTR in legacy mode
    dw 18*8-1           ; limit of IDT (size minus one)
    dd offset IDT32
endif
nullidt label fword
    dw 3FFh
    dd 0
llg label fword
llgofs dd offset long_start
    dw SEL_CODE64
  
    align 8
GDT dq 0                    ; null descriptor
    dw 0FFFFh,0,9A00h,0AFh  ; 64-bit code descriptor
    dw 0FFFFh,0,9200h,0CFh  ; 32-bit flat data descriptor
    dw 0FFFFh,0,9A00h,0h    ; 16-bit, 64k code descriptor
    dw 0FFFFh,0,9200h,0h    ; 16-bit, 64k data descriptor

if ?IDT32
IDT32 label qword
      dw offset exc3200+00,SEL_CODE16,8e00h,0	;00
      dw offset exc3200+04,SEL_CODE16,8e00h,0	;01
      dw offset exc3200+08,SEL_CODE16,8e00h,0	;02
      dw offset exc3200+12,SEL_CODE16,8e00h,0	;03
      dw offset exc3200+16,SEL_CODE16,8e00h,0	;04
      dw offset exc3200+20,SEL_CODE16,8e00h,0	;05
      dw offset exc3200+24,SEL_CODE16,8e00h,0	;06
      dw offset exc3200+28,SEL_CODE16,8e00h,0	;07
      dw offset exc3200+32,SEL_CODE16,8e00h,0	;08
      dw offset exc3200+36,SEL_CODE16,8e00h,0	;09
      dw offset exc3200+40,SEL_CODE16,8e00h,0	;0A
      dw offset exc3200+44,SEL_CODE16,8e00h,0	;0B
      dw offset exc3200+48,SEL_CODE16,8e00h,0	;0C
      dw offset exc3200+52,SEL_CODE16,8e00h,0	;0D
      dw offset exc3200+56,SEL_CODE16,8e00h,0	;0E
      dw offset exc3200+60,SEL_CODE16,8e00h,0	;0F
      dw offset exc3200+64,SEL_CODE16,8e00h,0	;10
      dw offset exc3200+68,SEL_CODE16,8e00h,0	;11
endif

savedint6x label dword
    dw offset jmpirq0,_TEXT16
    dw offset jmpirq1,_TEXT16
    dw offset jmpirq2,_TEXT16
    dw offset jmpirq3,_TEXT16
    dw offset jmpirq4,_TEXT16
    dw offset jmpirq5,_TEXT16
    dw offset jmpirq6,_TEXT16
    dw offset jmpirq7,_TEXT16
storedIRQ0_7 label dword
    dd 8 dup (?)

nthdr   IMAGE_NT_HEADERS <>
sechdr  IMAGE_SECTION_HEADER <>
xmsaddr dd 0
PhysAdr dd 0    ;physical address of allocated EMB
ImgBase dd 0
adjust  dd 0	;
fname   dd 0
dwSavedESP dd 0
        dw SEL_FLAT
emm     EMM <>
emm2    EMM <>
xmshdl  dw -1
fhandle dw -1
stkbot  dw 0 
        dw _TEXT16

wPICMask dw 0   ; variable to save/restore PIC masks

start16 proc
    push cs
    pop ds
    mov ax,cs
    movzx eax,ax
    shl eax,4
    add dword ptr [GDTR+2], eax ; convert offset to linear address
if ?IDT32
    add dword ptr [IDTR32+2], eax
endif
    mov word ptr [GDT + SEL_DATA16 + 2], ax
    mov word ptr [GDT + SEL_CODE16 + 2], ax
    shr eax,16
    mov byte ptr [GDT + SEL_DATA16 + 4], al
    mov byte ptr [GDT + SEL_CODE16 + 4], al

    mov ax,ss
    mov dx,es
    sub ax,dx
    mov bx,sp
    shr bx,4
    add bx,ax
    mov ah,4Ah
    int 21h         ; free unused memory
    push cs
    pop es

    mov ax,ss
    mov dx,cs
    sub ax,dx
    shl ax,4
    add ax,sp
    push ds
    pop ss
    mov sp,ax       ; make a TINY model, CS=SS=DS=ES
    mov stkbot,sp

    smsw ax
    test al,1
    jz @F
    @fatexit "Mode is V86. Need REAL mode to switch to LONG mode!"
@@:
    xor edx,edx
    mov eax,80000001h   ; test if long-mode is supported
    cpuid
    bt edx,29
    jc @F
    @fatexit "No 64bit cpu detected."
@@:
    mov ax,4300h
    int 2fh         ;XMS host available?
    test al,80h
    jnz @F
    @fatexit "No XMS host detected."
@@:
    push es
    mov ax,4310h
    int 2fh
    mov word ptr [xmsaddr+0],bx
    mov word ptr [xmsaddr+2],es
    pop es

    mov ah,5        ;local enable A20
    call xmsaddr

    push es
    mov ah,51h
    int 21h
    mov es,bx
    mov es,es:[002Ch]
    xor di,di
    xor al,al
    mov cx,-1
@@:
    repnz scasb
    cmp byte ptr es:[di],0
    jnz @B
    add di,3
    mov word ptr fname+0,di
    mov word ptr fname+2,es
    pop es
    push ds
    lds dx,fname
    mov ax,3D00h
    int 21h
    pop ds
    jnc @F
    @errorexit "cannot open file."
@@:
    mov fhandle,ax
    mov bx,ax
;--- load the file header
    sub sp,4096
    mov cx,sizeof IMAGE_DOS_HEADER
    mov dx,sp
    mov ah,3Fh
    int 21h
    cmp ax,cx
    jz @F
    @errorexit "invalid file format."
@@:
    movzx edx,dx
    cmp word ptr [edx].IMAGE_DOS_HEADER.e_magic,"ZM"
    jz @F
    @errorexit "invalid file format (no MZ header)."
@@:
    cmp word ptr [edx].IMAGE_DOS_HEADER.e_lfarlc,sizeof IMAGE_DOS_HEADER
    jnc @F
    @errorexit "invalid file format (MZ header too small)."
@@:
    mov cx,word ptr [edx].IMAGE_DOS_HEADER.e_lfanew+2
    mov dx,word ptr [edx].IMAGE_DOS_HEADER.e_lfanew+0
    mov ax,4200h
    int 21h
    mov dx,offset nthdr
    mov cx,sizeof IMAGE_NT_HEADERS
    mov ah,3Fh
    int 21h
    cmp ax,cx
    jz @F
    @errorexit "invalid file format (cannot locate PE header)."
@@:
    movzx esi,cx
    cmp dword ptr nthdr.Signature,"EP"
    jz @F
    @errorexit "invalid file format (no PE header)."
@@:
    cmp nthdr.FileHeader.Machine,IMAGE_FILE_MACHINE_AMD64
    jz @F
    @errorexit "not a 64-bit binary."
@@:
    test nthdr.FileHeader.Characteristics,IMAGE_FILE_RELOCS_STRIPPED
    jz @F
    @errorexit "relocations stripped, cannot load."
@@:
    cmp nthdr.OptionalHeader.Subsystem,IMAGE_SUBSYSTEM_NATIVE
    jz @F
    @errorexit "subsystem not native, cannot load."
@@:
    cmp nthdr.OptionalHeader.DataDirectory[IMAGE_DIRECTORY_ENTRY_IMPORT*sizeof IMAGE_DATA_DIRECTORY].Size_,0
    jz @F
    @errorexit "image contains imports, cannot load."
@@:
    cmp dword ptr nthdr.OptionalHeader.SizeOfStackReserve+4,0
    jz @F
    @errorexit "requested stack size of image is > 4 GB."
@@:
    mov edx, nthdr.OptionalHeader.SizeOfImage
    add edx, dword ptr nthdr.OptionalHeader.SizeOfStackReserve
    jc imagetoolarge
    shr edx,10      ;convert to kB
    test edx,0ffff0000h
    jz @F
imagetoolarge:
    @errorexit "image requires too much memory."
@@:
;--- add space for IDT and page tables
;--- needed: 1 page  for IDT
;---         1 page  for PML4 (1 PML4E, 512 GB)
;---         1 page  for PDPT (64 PDPTEs, 64 * 1GB )
;---        64 pages for PD (64 * 512 * PDEs, each 2MB )
;--- total: 67 pages = 268 kB     
    add dx, 268 + 3 ;extra 3 since we need to align to page boundary
    jc imagetoolarge
    mov ah,9
    call xmsaddr
    cmp ax,1
    jz @F
    @errorexit "XMS memory allocation failed."
@@:
    mov xmshdl,dx
    mov ah,0Ch      ;lock EMB 
    call xmsaddr
    cmp ax,1
    jz @F
    @errorexit "cannot lock EMB."
@@:
    mov word ptr PhysAdr+0,bx
    mov word ptr PhysAdr+2,dx
    mov word ptr ImgBase+0,bx
    mov word ptr ImgBase+2,dx
;--- copy the header into extended memory
    mov ecx, esi
    mov emm.srchdl, 0
    mov word ptr emm.srcofs+0, offset nthdr
    mov word ptr emm.srcofs+2, ds
    mov ax,xmshdl
    mov emm.dsthdl,ax
    mov emm.dstofs,0

;--- align to page boundary
    and bx,0fffh
    jz @F
    mov eax,1000h
    sub ax,bx
    mov emm.dstofs,eax
    mov adjust, eax
    add ImgBase, eax
@@:

    mov si,offset emm
    call copy2x

    mov di,sp
    mov bx,fhandle
    mov cx,nthdr.FileHeader.NumberOfSections
    .while cx
        push cx
        mov dx,offset sechdr
        mov cx,sizeof IMAGE_SECTION_HEADER
        mov ah,3Fh
        int 21h
        cmp ax,cx
        jz @F
        @errorexit "cannot load section headers."
@@:
        mov si,offset emm
        call copy2x
        call readsection
        pop cx
        dec cx
    .endw

    add sp,4096

    mov ah,3Eh
    int 21h
    mov fhandle,-1

    cli
    @lgdt [GDTR]        ; use 32-bit version of LGDT

    mov eax,cr0
    bts eax,0           ; enable pmode
    mov cr0,eax

    mov ax,SEL_DATA16
    mov ss,ax
    movzx esp,sp
    mov ds,ax
    mov ax,SEL_FLAT
    mov es,ax
    db 0eah
    dw offset @F
    dw SEL_CODE16
@@:

;--- handle base relocations
    mov edi, ImgBase
    mov esi, nthdr.OptionalHeader.DataDirectory[IMAGE_DIRECTORY_ENTRY_BASERELOC*sizeof IMAGE_DATA_DIRECTORY].VirtualAddress
    mov ecx, nthdr.OptionalHeader.DataDirectory[IMAGE_DIRECTORY_ENTRY_BASERELOC*sizeof IMAGE_DATA_DIRECTORY].Size_
    mov edx, edi
    sub edx, dword ptr nthdr.OptionalHeader.ImageBase
    add esi, edi    ;RVA->linear
    add ecx, esi    ;ecx=end of relocs (linear)
    push ds
    mov ax,es
    mov ds,ax
    assume ds:flat
nextpage:
    cmp esi, ecx
    jnc reloc_done
    push ecx
    @lodsd              ;get RVA of page
    mov ebx, eax
    add ebx, edi        ;convert RVA to linear address
    @lodsd
    lea ecx, [esi+eax-8];ecx=end of relocs for this page
    xor eax, eax
nextreloc:
    @lodsw
    test ah,0F0h        ;must be < 1000h (size of a page)
    jz ignreloc
    and ah,0Fh			;usually it's type 0A (dir64)
    add [eax+ebx], edx	;we adjust low32 only, since we cannot load beyond 4 GB
ignreloc:
    cmp esi, ecx
    jb nextreloc
    pop ecx
    jmp nextpage
reloc_done:
    pop ds
    assume ds:_TEXT16

;--- setup ebx/rbx with linear address of _TEXT
    mov bx,_TEXT
    movzx ebx,bx
    shl ebx,4
    add [llgofs], ebx

    mov edi,ImgBase
    add edi,nthdr.OptionalHeader.SizeOfImage
    add edi,dword ptr nthdr.OptionalHeader.SizeOfStackReserve

    call createIDT
    call createPgTabs
    call setpic

    mov eax,cr4
    bts eax,5           ; enable physical-address extensions (PAE)
    bts eax,9           ; also enable OSFXSR (no exception using SSE)
    mov cr4,eax

    mov ecx,0C0000080h  ; EFER MSR
    rdmsr
    bts eax,8           ; enable long mode
    wrmsr

;--- long_start expects:
;--- ecx = value of ESP in 64-bit
;--- esi = value of EIP in 64-bit
;--- ebx = image start

    mov ebx,ImgBase
    mov esi,nthdr.OptionalHeader.AddressOfEntryPoint
    add esi,ebx
    mov ecx,dword ptr nthdr.OptionalHeader.SizeOfStackReserve
    add ecx,nthdr.OptionalHeader.SizeOfImage
    add ecx,ebx

    mov eax,cr0
    bts eax,31
    mov cr0,eax         ; enable paging

    jmp [llg]

start16 endp

make_int_gates proc
    mov eax, edx
    add eax, ebx
    @stosw
    mov ax,SEL_CODE64
    @stosw
    mov ax,si           ;int/trap gate
    @stosd
    xor eax, eax
    @stosd
    @stosd
    loop make_int_gates
    ret
make_int_gates endp

if ?IDT32
;--- exception handlers for legacy protected-mode

    assume ss:flat

excno = 0
exc3200:
    repeat 16+2
    push excno
    jmp @F
    excno = excno+1
    endm
@@:
    mov dword ptr ss:[0B8000h],17201720h
    pop eax
    mov ah,al
    shr ah,4
    and ax,0F0Fh
    or  ax,3030h
    cmp al,3Ah
    jb @F
    add al,7
@@:
    mov ss:[0b8000h],ah
    mov ss:[0b8002h],al
    hlt    ;interrupts are disabled, so just stop
endif

;--- call real-mode thru DPMI function ax=0x300, bl=intno, edi=RMCS

call_rmode proc

    cli
    pushad
    mov ax,SEL_DATA16
    mov es,ax
    mov es:dwSavedESP,esp
    mov ss,ax
    movzx esp,ss:stkbot
    sub sp,sizeof RMCS
    mov ax, SEL_FLAT
    mov ds, ax
    push ss
    pop es
    cld
    mov esi,edi
    mov edi,esp
    mov ecx,(sizeof RMCS)/2
    @rep movsw

    shl bx,2
    mov eax,ds:[bx]
    mov dword ptr [esp].RMCS.regIP, eax
    cmp dword ptr [esp].RMCS.regSP,0
    jnz @F
    mov [esp].RMCS.regSP,sp
    mov [esp].RMCS.rSS,_TEXT16
@@:

;--- disable paging
    mov eax,cr0
    btr eax,31
    mov cr0, eax

;--- disable long mode
    mov ecx,0C0000080h  ; EFER MSR
    rdmsr
    btr eax,8
    wrmsr

    mov ax,SEL_DATA16   ; set DS and ES to 16bit, 64k data
    mov es,ax
    mov ds,ax

;--- switch to real-mode, then back to prot-mode

    mov eax,cr0
    and al,0feh
    mov cr0,eax
    jmp far16 ptr @F	; set CS to a real-mode segm
@@:
    mov ax, cs          ; SS=real-mode seg
    mov ss, ax
    @lidt cs:[nullidt]  ; IDTR=real-mode compatible values
    and byte ptr [esp].RMCS.rFlags+1,08Eh   ;reset IOPL, NT, TF
    popad
    popf
    pop es
    pop ds
    pop fs
    pop gs
    pop dword ptr cs:[adjust]	;use this field temporarily
    lss sp,ss:[esp]
    pushf
    cli
    push cs
    push offset backtopm
    jmp dword ptr cs:[adjust]
backtopm:
    lss sp,dword ptr cs:[stkbot]
    push gs
    push fs
    push ds
    push es
    pushf
    cli
    @lgdt cs:[GDTR]     ; use 32-bit version of LGDT
    pushad

    pushf
    and byte ptr [esp+1],8Eh	;reset NT,IOPL,TF
    popf

    mov eax,cr0
    or al,1
    mov cr0,eax
    mov ax,SEL_DATA16
    mov ss,ax
    mov ds,ax
    mov ax,SEL_FLAT
    mov es,ax
if 0
    db 0eah
    dw offset @F
    dw SEL_CODE16
@@:
endif
    @lidt [IDTR]
;--- (re)enable long mode
    mov ecx,0C0000080h  ; EFER MSR
    rdmsr
    bts eax,8           ; set long mode
    wrmsr

;--- (re)enable paging
    mov eax,cr0
    bts eax,31
    mov cr0, eax

    mov edi,dwSavedESP	;restore EDI
    mov edi,es:[edi]
    movzx esi,sp
    mov ecx,8+2
    cld
    @rep movsd
    @movsw
    lss esp, fword ptr dwSavedESP
    popad
    sti

    db 66h
    retf
call_rmode endp

;--- create IDT for long mode
;--- EDI->free memory
;--- ES=FLAT

createIDT proc
    mov dword ptr [IDTR+2], edi

    mov ecx,32
    mov edx, offset exception
    add edx, ebx
make_exc_gates:
    mov eax,edx
    @stosw
    mov ax,SEL_CODE64
    @stosw
    mov ax,8E00h
    @stosd
    xor eax, eax
    @stosd
    @stosd
    add edx,4
    loop make_exc_gates
    mov ecx,256-32
    mov edx,offset swint
    mov si, 8F00h
    call make_int_gates

    push edi
    lea edi,[edi-1000h]
    push edi
    lea edi,[edi+?MPIC*16]
    mov cx,8
    mov edx,offset Irq0007
    mov si, 8E00h
    call make_int_gates
    pop edi
    lea edi,[edi+?SPIC*16]
    mov cx,8
    mov edx,offset Irq080F
    call make_int_gates
    pop edi

    @lidt [IDTR]

    sub edi, 1000h

;--- setup IRQ0, Int21, Int31

    lea eax, [ebx+offset clock]
    mov es:[edi+(?MPIC+0)*16+0],ax ; set IRQ 0 handler
    shr eax,16
    mov es:[edi+(?MPIC+0)*16+6],ax

    lea eax,[ebx+offset int21]
    mov es:[edi+21h*16+0],ax ; set int 21h handler
;    mov word ptr es:[edi+21h*16+4],8F00h    ;change to trap gate
    shr eax,16
    mov es:[edi+21h*16+6],ax

    lea eax,[ebx+offset int31]
    mov es:[edi+31h*16+0],ax ; set int 31h handler
    shr eax,16
    mov es:[edi+31h*16+6],ax

    add edi, 1000h
    ret
createIDT endp

;--- setup page directories and tables
;--- EDI -> free memory
;--- ES=FLAT

createPgTabs proc

    add edi, 0fffh  ;align to page boundary
    and di,0f000h
    mov cr3, edi    ; load page-map level-4 base

    push edi
    mov ecx,02000h/4
    sub eax,eax
    @rep stosd       ; clear 2 pages (PML4 & PDPT)
    pop edi

;--- DI+0    : PML4
;--- DI+1000 : PDPT

    push edi
    mov eax,edi
    or eax,111b
    add eax, 1000h
    mov es:[edi+0h],eax     ; set first PML4E in PML4 (bits 38-47)
    add edi,1000h           ; let EDI point to PDPT
    mov cx,64               ; map 64 PDPTEs
    add eax, 1000h
nextpdpte:
    mov es:[edi],eax        ; set PDPTE in PDPT (bits 30-37)
    add eax, 1000h
    add edi,8
    loop nextpdpte
    pop edi
    add edi,2000h

;--- map the first 64 GBs (64 * 512 * 2MB pages)

    mov dl,16       ;16 * 4 GB
    mov esi,0
next4gb:
;--- init 4 PDEs (4 * 4 kB); this maps 4 GB
    mov cx,512*4            ; number of PDE entries in PD
    mov eax,87h             ; set PS (bit 7 -> page size = 2 MB)
@@:
    mov es:[edi+0],eax      ; set PDE in PD (bits 21-29)
    mov es:[edi+4],esi
    add edi,8
    add eax, 200000h
    loop @B
    inc esi
    dec dl
    jnz next4gb
    ret
createPgTabs endp

;--- DS=_TEXT16,ES=FLAT

storeirq07 proc
    mov cx,8
    mov bx,8*4
    mov di,offset storedIRQ0_7
nextitem:
    mov eax, es:[bx]
    mov [di], eax
    add bx,4
    add di,4
    loop nextitem
    ret
storeirq07 endp

;--- init the real-mode interrupts that are
;--- used for IRQs in long mode. This avoids
;--- having to restore them each time we temp. switch
;--- to real-mode.
;--- DS=_TEXT16,ES=FLAT

setintxxvecs proc
    mov cx,8
    mov bx,4*?MPIC
    mov di,offset savedint6x
nextitem:
    mov eax, [di]
    xchg eax, es:[bx]
    mov [di], eax
    add bx,4
    add di,4
    loop nextitem
    ret
setintxxvecs endp

;--- jmp to the IRQ handlers in real-mode
jmpirq0:jmp cs:[storedIRQ0_7+00]
jmpirq1:jmp cs:[storedIRQ0_7+04]
jmpirq2:jmp cs:[storedIRQ0_7+08]
jmpirq3:jmp cs:[storedIRQ0_7+12]
jmpirq4:jmp cs:[storedIRQ0_7+16]
jmpirq5:jmp cs:[storedIRQ0_7+20]
jmpirq6:jmp cs:[storedIRQ0_7+24]
jmpirq7:jmp cs:[storedIRQ0_7+28]

;--- reprogram PIC: change IRQ 0-7 to INT 80h-87h, IRQ 8-15 to INT 88h-8Fh
;--- ES=FLAT

setpic proc

    in al,0A1h
    mov ah,al
    in al,21h
    mov [wPICMask],ax

    call storeirq07
    call setintxxvecs

if ?MPIC ne 8
    mov al,10001b       ; begin PIC 1 initialization
    out 20h,al
    mov al,?MPIC        ; IRQ 0-7: interrupts 80h-87h
    out 21h,al
    mov al,100b         ; slave connected to IRQ2
    out 21h,al
    mov al,1            ; Intel environment, manual EOI
    out 21h,al
    in al,21h
endif
if ?SPIC ne 70h
    mov al,10001b       ; begin PIC 2 initialization
    out 0A0h,al
    mov al,?SPIC        ; IRQ 8-15: interrupts 88h-8Fh
    out 0A1h,al
    mov al,2
    out 0A1h,al
    in al,0A1h
endif
    mov ax,[wPICMask]
if ?MPIC ne 8
;    mov al,11111100b    ; enable only clock IRQ
    out 21h,al
endif
if ?SPIC ne 70h
;    mov al,11111111b
    mov al,ah
    out 0A1h,al
endif
    ret
setpic endp

;--- reprogram PIC: change IRQ 0-7 to INT 08h-0Fh
;--- ES=FLAT
;--- DS=_TEXT16

resetpic proc 

    mov al,10001b       ; begin PIC 1 initialization
    out 20h,al
;    mov al,10001b       ; begin PIC 2 initialization
;    out 0A0h,al
    mov al,08h          ; IRQ 0-7: back to ints 8h-Fh
    out 21h,al
;    mov al,70h          ; IRQ 8-15: back to ints 70h-77h
;    out 0A1h,al
    mov al,100b         ; slave connected to IRQ2
    out 21h,al
;   mov al,2
;    out 0A1h,al
    mov al,1            ; Intel environment, manual EOI
    out 21h,al
;    out 0A1h,al

    in al,21h
    mov ax,[wPICMask]   ; restore PIC masks
    out 21h,al
    mov al,ah
    out 0A1h,al

    call setintxxvecs

    ret
resetpic endp

;--- switch back to real-mode and exit

backtoreal proc
    cli

    mov ax,SEL_DATA16
    mov ds,ax
    mov ss,ax
    movzx esp,stkbot
    mov ax,SEL_FLAT
    mov es,ax
    call resetpic


    mov eax,cr0
    btr eax,31          ; disable paging
    mov cr0,eax

    mov ecx,0C0000080h  ; EFER MSR
    rdmsr
    btr eax,8           ; disable long mode (EFER.LME=0)
    wrmsr

    mov eax,cr4
    btr eax,5           ; disable PAE paging
    mov cr4,eax

    mov ax,SEL_DATA16   ; set SS, DS and ES to 16bit, 64k data
    mov es,ax

    mov eax,cr0         ; switch to real mode
    btr eax, 0
    mov cr0,eax
    jmp far16 ptr @F
@@:
    mov ax,STACK        ; SS=real-mode seg
    mov ss, ax

    push cs             ; DS=real-mode _TEXT16 seg
    pop ds

    @lidt [nullidt]     ; IDTR=real-mode compatible values

exit::
    mov bx,fhandle
    cmp bx,-1
    jz @F
    mov ah,3Eh
    int 21h
@@:
    mov dx,xmshdl
    cmp dx,-1
    jz @F
    mov ah,0dh          ;unlock handle
    call xmsaddr
    mov ah,0Ah          ;free EMB
    mov dx,xmshdl
    call xmsaddr
@@:
    cmp xmsaddr,0
    jz @F
    mov ah,6            ;local disable A20
    call xmsaddr
@@:
    sti
    mov ax,4c00h
    int 21h
backtoreal endp

;--- copy cx bytes to extended memory

copy2x proc
    mov [si].EMM._size,ecx
    push ecx
    push bx
    mov ah,0bh
    call xmsaddr
    pop bx
    pop ecx
    cmp ax,1
    jz @F
    @errorexit "error copying to extended memory."
@@:
    add [si].EMM.dstofs,ecx
    ret
copy2x endp

;--- read a section and copy it to extended memory
;--- DI = 4 kB buffer
;--- BX = file handle
;--- sechdr = current section

readsection proc
    mov ax,4201h
    xor cx,cx
    xor dx,dx
    int 21h
    push dx
    push ax

    mov emm2.srchdl, 0
    mov word ptr emm2.srcofs+0, di
    mov word ptr emm2.srcofs+2, ds
    mov ax,xmshdl
    mov emm2.dsthdl, ax
    mov eax, sechdr.VirtualAddress
    add eax, adjust
    mov emm2.dstofs, eax

    mov eax, sechdr.PointerToRawData
    push eax
    pop dx
    pop cx
    mov ax,4200h
    int 21h
    mov esi, sechdr.SizeOfRawData
    .while esi
        mov ecx,esi
        cmp ecx,1000h
        jb @F
        mov cx,1000h
@@:
        mov dx,di
        mov ah,3Fh
        int 21h
        cmp ax,cx
        jz @F
        @errorexit "cannot read section data."
@@:
        sub esi, ecx
        push si
        mov si,offset emm2
        call copy2x
        pop si
    .endw
    pop dx
    pop cx
    mov ax,4200h
    int 21h
    ret
readsection endp

_TEXT16 ends

;--- here's the 64bit code segment.
;--- since 64bit code is always flat but the DOS mz format is segmented,
;--- there are restrictions - because the assembler doesn't know the
;--- linear address where the 64bit segment will be loaded:
;--- + direct addressing with constants isn't possible (mov [0B8000h],rax)
;---   since the rip-relative address will be calculated wrong.
;--- + 64bit offsets (mov rax, offset <var>) must be adjusted by the linear
;---   address where the 64bit segment was loaded (is in rbx).

_TEXT segment para use64 public 'CODE'

    assume ds:FLAT, es:FLAT, ss:FLAT

long_start proc
    mov ax,SEL_FLAT
    mov ss,eax
    mov esp,ecx
    sti             ; now interrupts can be used
    call rsi
    mov ah,4Ch
    int 21h
long_start endp

;--- write a character

WriteChr proc
    push rdx
    push rax
    mov dl,al
    mov ah,2
    int 21h
    pop rax
    pop rdx
    RET
WriteChr endp

WriteStrX proc  ;write string at rip
    push rsi
    mov rsi, [rsp+8]
    cld
@@:
    lodsb
    and al,al
    jz @F
    mov dl,al
    mov ah,2
    int 21h
    jmp @B
@@:
    mov [rsp+8],rsi
    pop rsi
    ret
WriteStrX endp

WriteQW:        ;write QWord in rax
    push rax
    shr rax,32
    call WriteDW
    pop rax
WriteDW:
    push rax
    shr rax,16
    call WriteW
    pop rax
WriteW:
    push rax
    shr rax,8
    call WriteB
    pop rax
WriteB:     ;write Byte in al
    push rax
    shr rax,4
    call WriteNb
    pop rax
WriteNb:
    and al,0Fh
    add al,'0'
    cmp al,'9'
    jbe @F
    add al,7
@@:
    mov dl,al
    mov ah,2
    int 21h
    ret

;--- exception handler

exception:
excno = 0
    repeat 32
    push excno
    jmp @F
    excno = excno+1
    endm
@@:
    call WriteStrX
    db 13,10,"Exception ",0
    pop rax
    call WriteB
    call WriteStrX
    db " rsp=",0
    mov rax,rsp
    call WriteQW
if 0
    call WriteStrX
    db " rsi=",0
    mov rax,rsi
    call WriteQW
    call WriteStrX
    db " rdi=",0
    mov rax,rdi
    call WriteQW
endif
    call WriteStrX
    db 13,10," [rsp]=",0
    mov rax,[rsp+0]
    call WriteQW
    mov al,' '
    call WriteChr
    mov rax,[rsp+8]
    call WriteQW
    mov al,' '
    call WriteChr
    mov rax,[rsp+16]
    call WriteQW
    mov al,' '
    call WriteChr
    mov rax,[rsp+24]
    call WriteQW
    mov al,' '
    call WriteChr
    mov rax,[rsp+32]
    call WriteQW

    call WriteStrX
    db 13,10,"      ",0
    mov rax,[rsp+40]
    call WriteQW
    mov al,' '
    call WriteChr
    mov rax,[rsp+48]
    call WriteQW
    mov al,' '
    call WriteChr
    mov rax,[rsp+56]
    call WriteQW
    mov al,' '
    call WriteChr
    mov rax,[rsp+64]
    call WriteQW
    mov al,' '
    call WriteChr
    mov rax,[rsp+72]
    call WriteQW
    call WriteStrX
    db 13,10,0
    sti
    mov ax,4cffh
    int 21h

;--- clock and keyboard interrupts

clock:
    push rbp
    mov ebp,400h
    inc dword ptr [rbp+6Ch]
    pop rbp
Irq0007:
    push rax
Irq0007_1:
    mov al,20h
    out 20h,al
    pop rax
swint:
    iretq
Irq080F:
    push rax
    mov al,20h
    out 0A0h,al
    jmp Irq0007_1

;--- load lower 32-bit of 64-bit regs without loosing the upper 32bits

@loadreg macro reg
    push R&reg
    mov E&reg,[rsp+8].RMCS.rE&reg
    mov [rsp],E&reg
    pop R&reg
endm

;--- simple int 21h handler.
;--- handles ah=4Ch
;--- any other DOS function is transfered to real-mode

int21 proc
    cmp ah,4Ch
    jz int21_4c
    and byte ptr [rsp+2*8],0FEh ;clear carry flag
    sub rsp,38h
    mov [rsp].RMCS.rEDI, edi
    mov [rsp].RMCS.rESI, esi
    mov [rsp].RMCS.rEBP, ebp
    mov [rsp].RMCS.rEBX, ebx
    mov [rsp].RMCS.rEDX, edx
    mov [rsp].RMCS.rECX, ecx
    mov [rsp].RMCS.rEAX, eax
    mov word ptr [rsp].RMCS.rFlags, 0002h
    mov word ptr [rsp].RMCS.rDS, _TEXT
    mov word ptr [rsp].RMCS.rES, _TEXT
    mov dword ptr [rsp].RMCS.regSP, 0
    push rdi
    lea rdi,[rsp+8]
    mov bx,21h
    mov cx,0
    mov ax,0300h
    int 31h
    pop rdi
    jnc int21_exit
    or  byte ptr [rsp+38h+2*8],1    ;set carry flag
int21_exit:
    @loadreg DI
    @loadreg SI
    @loadreg BP
    @loadreg BX
    @loadreg DX
    @loadreg CX
    @loadreg AX
    lea rsp,[rsp+38h]
    iretq
int21_4c:
    jmp [bv]
bv  label ptr far32
    dd offset backtoreal
    dw SEL_CODE16
int21 endp

int31 proc
    cmp ax,0300h
    jz int31_300
ret_with_carry:
    or byte ptr [rsp+2*8],1 ;set carry flag
    iretq
int31_300:
    and byte ptr [rsp+2*8],0FEh
    call [v86]
    jc ret_with_carry
    iretq
v86 label ptr far32
    dd offset call_rmode	;use a far32 call to ensure HIWORD(EIP) isn't lost
    dw SEL_CODE16
int31 endp

_TEXT ends

;--- 5k stack, used in 16-bit modes

STACK segment use16 para stack 'STACK'
    db 5120 dup (?)
STACK ends

    end start16
