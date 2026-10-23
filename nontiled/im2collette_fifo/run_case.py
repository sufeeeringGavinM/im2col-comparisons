"""Run the packaged RTL on supplied hexadecimal tensors or generated fixtures."""
from pathlib import Path
import argparse
import json
import os
import re
import shutil
import subprocess
import sys


def windows_to_wsl():
    path_options={'--input-file','--kernel-file','--expected-file','--out-dir','--wave-file'}
    def convert(value):
        return subprocess.check_output(['wsl.exe','--exec','wslpath','-u',str(Path(value).expanduser().resolve())],text=True).strip()
    arguments=[]
    pending=False
    for value in sys.argv[1:]:
        if pending:
            arguments.append(convert(value));pending=False
        elif '=' in value and value.split('=',1)[0] in path_options:
            name,path=value.split('=',1);arguments.append(name+'='+convert(path))
        else:
            arguments.append(value);pending=value in path_options
    script=convert(__file__)
    raise SystemExit(subprocess.call(['wsl.exe','--cd',script.rsplit('/',1)[0],'--exec','python3',script,*arguments]))


if os.name=='nt' and not (shutil.which('iverilog') and shutil.which('vvp')):
    windows_to_wsl()

from gen_matrices import TENSOR_ARGUMENTS, convolve, create_parser, output_shape, write_hex_tensor


def read_tensor(path,bits):
    text=path.read_text()
    shape_match=re.search(r'shape\s*=\(([^)]*)\)',text)
    shape=tuple(int(value.strip()) for value in shape_match[1].split(',') if value.strip()) if shape_match else None
    values=[int(word,16) for line in text.splitlines() for word in line.split('//',1)[0].split()]
    if any(value<0 or value>=(1<<bits) for value in values):
        raise ValueError(f'{path}: expected unsigned {bits}-bit hexadecimal encodings')
    return values,shape


def main():
    project=Path(__file__).resolve().parent
    metadata=json.loads((project/'config.json').read_text())
    parser=create_parser()
    parser.description=__doc__
    dimensions=['N','C','H','W','K','R','S']
    parser.set_defaults(**{name:None for name in dimensions},out_dir=project/'runs/latest')
    parser.add_argument('--input-file',type=Path)
    parser.add_argument('--kernel-file',type=Path)
    parser.add_argument('--expected-file',type=Path,help='Optional independent 32-bit hex expected output')
    parser.add_argument('--wave-file',type=Path)
    parser.add_argument('--tiled',action='store_true',help='Compatibility flag; folder selects the simulation top')
    args=parser.parse_args()
    if bool(args.input_file)!=bool(args.kernel_file):
        parser.error('Provide both --input-file and --kernel-file')
    if args.tiled and metadata['mode']!='tiled':
        parser.error('This folder contains a non-tiled implementation')
    output=args.out_dir.expanduser().resolve()
    reserved={output/name for name in ['input_used.txt','kernel_used.txt','expected_python.txt','output_tensor.txt','compile.log','simulation.log','simulation.vvp','result.json','sram_layout.txt']}
    if any(path is not None and path.expanduser().resolve() in reserved for path in [args.input_file,args.kernel_file,args.expected_file]):
        parser.error('Choose an --out-dir that will not overwrite a supplied tensor')
    defaults=dict(TENSOR_ARGUMENTS)
    if args.input_file:
        inputs,input_shape=read_tensor(args.input_file.expanduser().resolve(),8)
        kernels,kernel_shape=read_tensor(args.kernel_file.expanduser().resolve(),8)
        for shape,names in [(input_shape,['N','C','H','W']),(kernel_shape,['K','C','R','S'])]:
            if shape is not None:
                if len(shape)!=4:
                    parser.error('Tensor shape headers must contain four dimensions')
                for name,value in zip(names,shape):
                    supplied=getattr(args,name)
                    if supplied is not None and supplied!=value:
                        parser.error(f'{name} disagrees with tensor shape header')
                    setattr(args,name,value)
        missing=[name for name in dimensions if getattr(args,name) is None]
        if missing:
            parser.error('Without shape headers, provide dimensions: '+', '.join('--'+name for name in missing))
    else:
        for name in dimensions:
            if getattr(args,name) is None:
                setattr(args,name,defaults[name])
        output.mkdir(parents=True,exist_ok=True)
        generator_args=[part for name,_ in TENSOR_ARGUMENTS for part in ['--'+name,str(getattr(args,name))]]
        subprocess.run([sys.executable,str(project/'gen_matrices.py'),*generator_args,'--seed',str(args.seed),'--out-dir',str(output)],check=True)
        inputs,_=read_tensor(output/'input_tensor.txt',8)
        kernels,_=read_tensor(output/'kernel_tensor.txt',8)
    if min(args.pad_i,args.pad_j)<0 or min(args.stride_i,args.stride_j)<1:
        parser.error('Padding must be nonnegative and strides positive')
    height,width=output_shape(args)
    if height<1 or width<1:
        parser.error('Kernel does not fit the padded input')
    if len(inputs)!=args.N*args.C*args.H*args.W or len(kernels)!=args.K*args.C*args.R*args.S:
        parser.error('Input/kernel word counts disagree with the configured tensor shapes')
    if metadata['mode']=='tiled':
        if len(inputs)+len(kernels)+args.N*args.K*height*width+32>65536:
            parser.error('Layer exceeds the existing testbench backing memory')
    else:
        if max(args.C,args.K)>10 or args.C*args.R*args.S>256 or args.N*height*width>256:
            parser.error('Layer exceeds the original non-tiled channel/kernel/output limits')
        activation_words=args.N*args.H*args.W
        if metadata['layout']=='swizzled':
            activation_words=((args.C*args.R*args.S+9)//10)*((args.H+args.R-1)//args.R)*((args.W+args.S-1)//args.S)*args.N
        if activation_words>256:
            parser.error('Layer exceeds activation-bank capacity for this storage layout')
        if metadata['implementation']=='explicit' and args.N*height*width*args.R*args.S>65536:
            parser.error('Layer exceeds an explicit im2col scratch bank')
    signed_inputs=[value-256 if value>=128 else value for value in inputs]
    signed_kernels=[value-256 if value>=128 else value for value in kernels]
    expected=convolve(signed_inputs,signed_kernels,args)
    if args.expected_file:
        supplied,shape=read_tensor(args.expected_file.expanduser().resolve(),32)
        if shape is not None and shape!=(args.N,args.K,height,width):
            parser.error('Expected tensor header disagrees with output shape')
        if supplied!=expected:
            parser.error('Supplied expected output disagrees with the Python golden model')
    output.mkdir(parents=True,exist_ok=True)
    write_hex_tensor(output/'input_used.txt',(args.N,args.C,args.H,args.W),inputs,8)
    write_hex_tensor(output/'kernel_used.txt',(args.K,args.C,args.R,args.S),kernels,8)
    write_hex_tensor(output/'expected_python.txt',(args.N,args.K,height,width),expected,32)
    compiler=os.environ.get('IVERILOG_BIN') or shutil.which('iverilog')
    runtime=os.environ.get('VVP_BIN') or shutil.which('vvp')
    backend=os.environ.get('IVERILOG_BACKEND')
    if not compiler or not runtime:
        parser.error('Install Icarus Verilog and put iverilog and vvp on PATH; see README.md')
    top='tb_conv_accelerator' if metadata['mode']=='tiled' else 'tb_conv_core'
    binary=output/'simulation.vvp'
    command=[str(compiler),*(['-B',backend] if backend else []),'-g2012','-Wall','-I','sim','-s',top,f'-P{top}.ARRAY_SIZE=10','-o',str(binary),f'sim/{top}.v',*[str(path.relative_to(project)) for path in sorted((project/'rtl').glob('*.v'))]]
    with (output/'compile.log').open('w') as log:
        compiled=subprocess.run(command,cwd=project,stdout=log,stderr=subprocess.STDOUT,timeout=300)
    if compiled.returncode:
        raise RuntimeError('Compilation failed; see '+str(output/'compile.log'))
    actual=output/'output_tensor.txt'
    arguments=[f'+{name}={getattr(args,name)}' for name,_ in TENSOR_ARGUMENTS]
    arguments.extend([f'+INPUT_FILE={output}/input_used.txt',f'+KERNEL_FILE={output}/kernel_used.txt',f'+OUTPUT_FILE={actual}',f'+SRAM_LAYOUT_FILE={output}/sram_layout.txt'])
    if args.wave_file:
        arguments.append('+WAVE_FILE='+str(args.wave_file.expanduser().resolve()))
    with (output/'simulation.log').open('w') as log:
        simulated=subprocess.run([str(runtime),*(['-M',backend] if backend else []),str(binary),*arguments],cwd=project,stdout=log,stderr=subprocess.STDOUT,timeout=300)
    log=(output/'simulation.log').read_text(errors='replace')
    if simulated.returncode or 'PASS:' not in log or re.search(r'FATAL:|ERROR:',log):
        raise RuntimeError('Simulation failed; see '+str(output/'simulation.log')+'\n'+log[-2000:])
    observed,_=read_tensor(actual,32)
    if observed!=expected:
        raise RuntimeError('RTL output differs from Python golden output')
    record=dict(status='PASS',implementation=metadata['implementation'],mode=metadata['mode'],config={name:getattr(args,name) for name,_ in TENSOR_ARGUMENTS},output_shape=[args.N,args.K,height,width],outputs=len(expected),checks=['Verilog reference task','Python golden model'],metrics=[line for line in log.splitlines() if any(tag in line for tag in ['[METRIC]','[CYCLES]','[PACKETS]'])],actual_file=str(actual))
    (output/'result.json').write_text(json.dumps(record,indent=2)+'\n')
    print(f"PASS: {len(expected)} outputs match Verilog and Python references. Results: {output}")


if __name__=='__main__':
    try:
        main()
    except (ValueError,RuntimeError,subprocess.SubprocessError,OSError) as error:
        print('Error: '+str(error),file=sys.stderr)
        raise SystemExit(1)
