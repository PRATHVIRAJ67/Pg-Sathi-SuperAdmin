import { forwardRef, type InputHTMLAttributes, type ReactNode, type SelectHTMLAttributes, type TextareaHTMLAttributes } from 'react';
import { Checkbox as CheckboxPrimitive, Switch as SwitchPrimitive, Label as LabelPrimitive } from 'radix-ui';
import { Check, ChevronDown } from 'lucide-react';
import { cn } from '../utils';

const fieldBase =
  'w-full rounded-md border border-gray-200 bg-white text-sm text-gray-900 shadow-xs transition-[border-color,box-shadow] placeholder:text-gray-400 hover:border-gray-300 focus-visible:border-accent-600 focus-visible:outline-none focus-visible:ring-3 focus-visible:ring-accent-100 disabled:cursor-not-allowed disabled:bg-gray-50 disabled:text-gray-500 aria-[invalid=true]:border-danger-600 aria-[invalid=true]:focus-visible:ring-danger-100';

export interface InputProps extends InputHTMLAttributes<HTMLInputElement> {
  leading?: ReactNode;
  trailing?: ReactNode;
}

export const Input = forwardRef<HTMLInputElement, InputProps>(({ className, leading, trailing, ...props }, ref) => {
  if (!leading && !trailing) {
    return <input ref={ref} className={cn(fieldBase, 'h-9 px-3', className)} {...props} />;
  }
  return (
    <div className="relative">
      {leading && (
        <span className="pointer-events-none absolute inset-y-0 left-3 flex items-center text-gray-400 [&_svg]:size-4">{leading}</span>
      )}
      <input ref={ref} className={cn(fieldBase, 'h-9', leading ? 'pl-9' : 'pl-3', trailing ? 'pr-10' : 'pr-3', className)} {...props} />
      {trailing && <span className="absolute inset-y-0 right-3 flex items-center text-xs text-gray-400">{trailing}</span>}
    </div>
  );
});
Input.displayName = 'Input';

/** Rupee input: shows ₹ and uses a numeric keypad on mobile. Value is a rupee string. */
export const MoneyInput = forwardRef<HTMLInputElement, Omit<InputProps, 'leading' | 'type' | 'inputMode'>>(({ className, ...props }, ref) => (
  <Input ref={ref} type="text" inputMode="decimal" autoComplete="off" leading={<span className="text-sm text-gray-500">₹</span>} className={cn('tabular', className)} {...props} />
));
MoneyInput.displayName = 'MoneyInput';

export const Textarea = forwardRef<HTMLTextAreaElement, TextareaHTMLAttributes<HTMLTextAreaElement>>(({ className, ...props }, ref) => (
  <textarea ref={ref} className={cn(fieldBase, 'min-h-20 px-3 py-2 leading-relaxed', className)} {...props} />
));
Textarea.displayName = 'Textarea';

export const Select = forwardRef<HTMLSelectElement, SelectHTMLAttributes<HTMLSelectElement>>(({ className, children, ...props }, ref) => (
  <div className="relative">
    <select ref={ref} className={cn(fieldBase, 'h-9 appearance-none pl-3 pr-9', className)} {...props}>
      {children}
    </select>
    <ChevronDown className="pointer-events-none absolute right-3 top-1/2 size-4 -translate-y-1/2 text-gray-400" aria-hidden />
  </div>
));
Select.displayName = 'Select';

export function Label({ className, ...props }: LabelPrimitive.LabelProps) {
  return <LabelPrimitive.Root className={cn('text-[13px] font-medium text-gray-700', className)} {...props} />;
}

export function Checkbox({ className, ...props }: CheckboxPrimitive.CheckboxProps) {
  return (
    <CheckboxPrimitive.Root
      className={cn(
        'peer size-4 shrink-0 rounded-[4px] border border-gray-300 bg-white shadow-xs transition-colors data-[state=checked]:border-accent-600 data-[state=checked]:bg-accent-600 data-[state=checked]:text-white focus-visible:outline-2 focus-visible:outline-offset-2 focus-visible:outline-accent-600 disabled:opacity-50',
        className,
      )}
      {...props}
    >
      <CheckboxPrimitive.Indicator className="flex items-center justify-center">
        <Check className="size-3" strokeWidth={3} />
      </CheckboxPrimitive.Indicator>
    </CheckboxPrimitive.Root>
  );
}

export function Switch({ className, ...props }: SwitchPrimitive.SwitchProps) {
  return (
    <SwitchPrimitive.Root
      className={cn(
        'peer inline-flex h-5 w-9 shrink-0 items-center rounded-full border-2 border-transparent bg-gray-200 transition-colors data-[state=checked]:bg-accent-600 focus-visible:outline-2 focus-visible:outline-offset-2 focus-visible:outline-accent-600 disabled:opacity-50',
        className,
      )}
      {...props}
    >
      <SwitchPrimitive.Thumb className="pointer-events-none block size-4 rounded-full bg-white shadow-sm transition-transform data-[state=checked]:translate-x-4" />
    </SwitchPrimitive.Root>
  );
}
